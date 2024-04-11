local masterDimmer = -1
local fadeDuration = -1
local loopCount = -1

local SendFadeDuration = false

local LogReceived = false

local SendUpdates = false
local Connected = false
local blinkTimer = 0
local updateTimer = 0
local lastReceived = 0
local currentPreset = ""
local currentCue = ""
IP = ""
port = 8000



local function lpak(_, ...)
  return string.pack(...)
end

local oLvpk= {pack = lpak, unpack = string.unpack}
local mtab = {0, 3, 2, 1}

-- ++++++++++++++++++++++++++++++++++++++++++++++++++++
-- osc private functions
local endpad = string.char(0, 0, 0, 0)
function oscString (Str)
local newS = Str..string.char(0x0)
local mod = string.len(newS) % 4
  return(newS..string.sub(endpad, 1, mtab[mod + 1]))
end

function oscType (Str)
  return(oscString(','..Str))
end

function oscSymbol (Str)
  local s1, _ = string.find(Str, " ")
  return(oscString(string.sub(Str, 1, s1)))
end

function align4(n)
  return (math.floor((n-1)/4) + 1) * 4
end

function padBin(binD)
  local nwD = binD
  for i=1, align4(#binD)-#binD do nwD = nwD..string.char(0) end
  return nwD
end
-- +++++++++++++++++++++++++++++++++++++++++++++++++++
-- Creates an OSC packet
-- currently accepts the following types:
-- s  string
-- S  alt string
-- c  a char (32 bit int)
-- i  int (32-bit)
-- m  MIDI data, four bytes: channel, status, d1, d2
-- t  TIME data, two 32 ints: seconds, fraction of seconds
-- f  float (32-bit)
-- b  BLOB data, binary bytes
-- h  signed int (64-bit)
-- d  double float (64-bit)
--        The following have NO data block (but are DEcoded to a string: 'NIL', 'TRUE', etc...
-- N  NIL
-- T  TRUE
-- F  FALSE
-- I  Infinitum
-- [  Array begin
-- ]  Array end
function oscPacket (addrS, typeS, msgTab)
  local strl, types --, tBlb
  
  if  typeS == nil then
    strl = oscString(addrS)..oscType('') -- no type & no data...EMPTY type block included in msg (comma and three zeros)
  else
      strl = oscString(addrS)..oscType(typeS)
    
      if msgTab ~= nil then -- add data if type has arguments...some do not
      for argC = 1, #msgTab do
        types = string.sub(typeS, argC, argC)
          if types == 's' or types == 'S' then 
            strl = strl..oscString(msgTab[argC])
          elseif types == 'f' then
            strl = strl..oLvpk.pack('string', '>f', msgTab[argC])
          elseif types == 'i' then
            strl = strl..oLvpk.pack('string', '>i4', msgTab[argC])
          elseif types == 'b' then 
            local tBlb = padBin(msgTab[argC])
            strl = strl..oLvpk.pack('string', '>i4', #msgTab[argC])..tBlb
          elseif types == 'h' then
            strl = strl..oLvpk.pack('string', '>i8', msgTab[argC])
          elseif types == 'd' then
            strl = strl..oLvpk.pack('string', '>d', msgTab[argC])
          elseif types == 'c' then
            strl = strl..oLvpk.pack('string', '>I', tostring( utf8.codepoint(msgTab[argC])))
          elseif types == 'm' then
            strl = strl..oLvpk.pack('string', 'c4', msgTab[argC])
          elseif types == 't' then
            strl = strl..oLvpk.pack('string', 'c8', msgTab[argC])
          elseif types == 'N' or types == 'T' or types == 'F' or types == 'I' or types == string.char(91) or types == string.char(93) then
            -- no data
          else
            return (nil)  -- unknown type
          end
        end
      end
    end
  return(strl)
end
-- unpack UDP OSC msg packet into:
--	oscAddr = oA
--	oscType = oT
--	oscData = oD
function oscUnpack(udpM)
  local oA ,oT, oD
    
    oA = udpM:match("^[%p%w]+%z+")
    oT = udpM:match(',[%a%[+%]+]+')
    if oA ~= nil then
      local aBlk = #oA 
      oA = oA:gsub('%z', '')
      if oT ~= nil then
        local dataBlk = aBlk + (math.floor((#oT)/4) + 1) * 4
        oD = string.sub(udpM, dataBlk + 1)
        oT = oT:match('[^,]+')
      end
    end
    return oA, oT, oD
  end
-- unpack OSC data block
-- currently unpacks the following types:
-- s  string
-- S  alt string
-- c  a char (but 32 bit int)
-- i  int (32-bit)
-- m  MIDI data, four bytes: channel, status, d1, d2
-- t  TIME data, two 32 ints: seconds, fraction of seconds
-- f  float (32-bit)
-- b  BLOB data, binary bytes
-- h  signed int (64-bit)
-- d  double float (64-bit)
--        These have no data block; a string ID is inserted in unpack table:
-- N  'NIL'
-- T  'TRUE'
-- F  'FALSE'
-- I  'INFINITUM'
-- [  'ARRAY_BEGIN'
-- ]  'ARRAY_END'
function oscDataUnpack(oT, oD)
  local tc, iv, nx, zloc
  local dTbl = {}
    if oT ~= nil then
      for i = 1, #oT do
        tc = oT:sub(i,i)
        if tc == 'f' then
          iv, nx = oLvpk.unpack(">f", oD)
          oD = string.sub(oD, 5)
          table.insert(dTbl, tonumber(iv))
        elseif tc == 's' or tc == 'S' then
          zloc, nx = string.find(oD, '\0')
          local tmpS = string.sub(oD, 1, zloc - 1)
          iv = string.format("%s", tmpS)
          nx = zloc + mtab[zloc % 4 + 1]
          oD = string.sub(oD, nx + 1)
          table.insert(dTbl, tostring(iv))
        elseif tc == 'b' then
          iv, nx = oLvpk.unpack(">i", oD)
          local blb = string.sub(oD, 1, iv + nx)  
          oD = string.sub(oD, align4(iv -1) + nx)
          table.insert(dTbl, blb)
        elseif tc == 'i' or tc == 'r' then
          iv, nx = oLvpk.unpack(">i", oD)
          oD = string.sub(oD, 5)
          table.insert(dTbl, tonumber(iv))
        elseif tc == 'c' then
          iv, nx = oLvpk.unpack(">i", oD)
          oD = string.sub(oD, 5)
          table.insert(dTbl, utf8.char(iv))
        elseif tc == 'm' then
          iv, nx = oLvpk.unpack("c4", oD)
          oD = string.sub(oD, 5)
          table.insert(dTbl, iv)
        elseif tc == 't' then
          iv, nx = oLvpk.unpack("c8", oD)
          oD = string.sub(oD, 9)
          table.insert(dTbl, iv)
        elseif tc == 'h' then
          iv, nx = oLvpk.unpack(">i8", oD)
          oD = string.sub(oD, 9)
          table.insert(dTbl, tonumber(iv))
        elseif tc == 'd' then
          iv, nx = oLvpk.unpack(">d", oD)
          oD = string.sub(oD, 9)
          table.insert(dTbl, tonumber(iv))
        elseif tc == 'I' then
          table.insert(dTbl, 'IMPULSE')
        elseif tc == 'T' then
          table.insert(dTbl, 'TRUE')
        elseif tc == 'F' then
          table.insert(dTbl, 'FALSE')
        elseif tc == 'N' then
          table.insert(dTbl, 'NIL')
        elseif tc == string.char(91) then
          table.insert(dTbl, 'ARRAY_BEGIN')
        elseif tc == string.char(93) then
          table.insert(dTbl, 'ARRAY_END')
        end
      end
    end
      return dTbl
  end    

-- Initialize
udpInitialized = false
NamedControl.SetPosition("Connected", 0)
NamedControl.SetText("StatusDisplay", "")

OscSocket = UdpSocket.New()

function SetActive(ledControl, codeControl, currentValue)
    local ledValue

    if currentValue == NamedControl.GetText(codeControl) then
      ledValue = 1
    else
      ledValue = 0
    end

    NamedControl.SetPosition(ledControl, ledValue)
end

function HandleData(socket, packet) 
    local oscADDR, oscTYPE, oscDATA = oscUnpack(packet.Data)
    local dataT = oscDataUnpack(oscTYPE, oscDATA)

    lastReceived = updateTimer

    if oscADDR == "/dmxcore/dimmer/master" and dataT[1] ~= nil then
        print("Master dimmer = " .. dataT[1])
        NamedControl.SetPosition("MasterDimmer", dataT[1])
    elseif oscADDR == "/dmxcore/status/preset" and dataT[1] ~= nil then
        print("Preset = " .. dataT[1])
        currentPreset = dataT[1]
        if currentPreset ~= "" then
            currentCue = ""
        end
    elseif oscADDR == "/dmxcore/status/cue" and dataT[1] ~= nil then
        print("Cue = " .. dataT[1])
        currentCue = dataT[1]
        if currentCue ~= "" then
            currentPreset = ""
        end
    elseif oscADDR == "/dmxcore/status/text" and dataT[1] ~= nil then
        print("Status = " .. dataT[1])
        NamedControl.SetText("StatusDisplay", dataT[1])
    end

    SetActive("PresetActive1", "PresetCode1", currentPreset)
    SetActive("PresetActive2", "PresetCode2", currentPreset)
    SetActive("PresetActive3", "PresetCode3", currentPreset)
    SetActive("PresetActive4", "PresetCode4", currentPreset)
    SetActive("PresetActive5", "PresetCode5", currentPreset)
    SetActive("PresetActive6", "PresetCode6", currentPreset)

    SetActive("CueActive1", "CueCode1", currentCue)
    SetActive("CueActive2", "CueCode2", currentCue)
    SetActive("CueActive3", "CueCode3", currentCue)
    SetActive("CueActive4", "CueCode4", currentCue)
    SetActive("CueActive5", "CueCode5", currentCue)
    SetActive("CueActive6", "CueCode6", currentCue)

    if LogReceived then
        -- output to console
        print(oscADDR, oscTYPE)
        if dataT ~= nil then
          for i, v in ipairs(dataT) do
              print(i..')', v)
          end
        end
    end
end

function ConnectTimerCallback ()
    IP = NamedControl.GetText("IP")

    --check if initialized, i.e IP valid and UDP port open
    if udpInitialized == false then
    
        --before can send message need to determine IP address is valid IP address
        if Device.LocalUnit.ControlIP ~= nil then
            --have an IP Address
            print("Offline: " .. tostring(Device.Offline))
            print("Valid IP: " .. tostring(Device.LocalUnit.ControlIP))
            OscSocket:Open(Device.LocalUnit.ControlIP, 9000)
            OscSocket.Data = HandleData

            NamedControl.SetPosition("Connected", 1)
            udpInitialized = true --have done initial setup, so set this as true so don't need to do again.

            OscSocket:Send(IP, port, oscPacket('/dmxcore/status', nil, {}))
          else
            --IP address not ready, Try again next Timer pass
            print("Not ready Online Path with Device IP: " .. tostring(Device.LocalUnit.ControlIP))
        end
    end

    blinkTimer = blinkTimer + 1

    --if blinkTimer % 1 == 0 then
    NamedControl.SetPosition("Active", blinkTimer % 2)

    if blinkTimer == 5 then
        -- 5 seconds
        print("Sending Ping Message")
        OscSocket:Send(IP, port, oscPacket('/ping', nil, {}))
        blinkTimer = 0
    end
end

ConnectTimer = Timer.New()
ConnectTimer.EventHandler = ConnectTimerCallback
ConnectTimer:Start(1)

function MainTimerCallback ()
    local state
    local sendUpdate = SendUpdates

    updateTimer = updateTimer + 1

    if udpInitialized == false then
        return
    end

    if updateTimer - lastReceived < 2 then
        -- To prevent feedback
        sendUpdate = false
    end

    state = NamedControl.GetPosition("MasterDimmer")
    if state ~= masterDimmer and state ~= nil then
        masterDimmer = state

        if sendUpdate then
            print("Sending Master Dimmer = " .. state)
            OscSocket:Send(IP, port, oscPacket('/dmxcore/dimmer/master', 'f', { state } ))
        end
    end

    state = NamedControl.GetValue("FadeDuration")
    if state ~= fadeDuration and state ~= nil and SendUpdates then
        if SendFadeDuration and sendUpdate then
            print("Sending UDP Message to " .. IP)
            OscSocket:Send(IP, port, oscPacket('/dmxcore/config/fadeduration', 'i', { math.floor(state * 1000) } ))
        end

        -- Save it into our variable since we're using that in other places
        fadeDuration = state
    end

    state = NamedControl.GetValue("FadeToBlack")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/dimmer/master/fadeto', 'fi', { 0, math.floor(fadeDuration * 1000) } ))
        NamedControl.SetValue("FadeToBlack", 0)
    end

    state = NamedControl.GetValue("FadeTo100")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/dimmer/master/fadeto', 'fi', { 1, math.floor(fadeDuration * 1000) } ))
        NamedControl.SetValue("FadeTo100", 0)
    end

    state = NamedControl.GetValue("GoToPreset1")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/preset/' .. NamedControl.GetText("PresetCode1"), 'i', { math.floor(fadeDuration * 1000) } ))
        NamedControl.SetValue("GoToPreset1", 0)
    end

    state = NamedControl.GetValue("GoToPreset2")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/preset/' .. NamedControl.GetText("PresetCode2"), 'i', { math.floor(fadeDuration * 1000) } ))
        NamedControl.SetValue("GoToPreset2", 0)
    end

    state = NamedControl.GetValue("GoToPreset3")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/preset/' .. NamedControl.GetText("PresetCode3"), 'i', { math.floor(fadeDuration * 1000) } ))
        NamedControl.SetValue("GoToPreset3", 0)
    end

    state = NamedControl.GetValue("GoToPreset4")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/preset/' .. NamedControl.GetText("PresetCode4"), 'i', { math.floor(fadeDuration * 1000) } ))
        NamedControl.SetValue("GoToPreset4", 0)
    end

    state = NamedControl.GetValue("GoToPreset5")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/preset/' .. NamedControl.GetText("PresetCode5"), 'i', { math.floor(fadeDuration * 1000) } ))
        NamedControl.SetValue("GoToPreset5", 0)
    end

    state = NamedControl.GetValue("GoToPreset6")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/preset/' .. NamedControl.GetText("PresetCode6"), 'i', { math.floor(fadeDuration * 1000) } ))
        NamedControl.SetValue("GoToPreset6", 0)
    end

    state = NamedControl.GetValue("LoopCount")
    if state ~= loopCount and state ~= nil and SendUpdates then
        -- Save it into our variable since we're using that in other places
        loopCount = math.floor(state + 0.5)
    end

    state = NamedControl.GetValue("StopPlayback")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/cuecontrol/stop', nil, {} ))
        NamedControl.SetValue("StopPlayback", 0)
    end

    state = NamedControl.GetValue("PlayCue1")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/cue/' .. NamedControl.GetText("CueCode1"), 'i', { loopCount } ))
        NamedControl.SetValue("PlayCue1", 0)
    end

    state = NamedControl.GetValue("PlayCue2")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/cue/' .. NamedControl.GetText("CueCode2"), 'i', { loopCount } ))
        NamedControl.SetValue("PlayCue2", 0)
    end

    state = NamedControl.GetValue("PlayCue3")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/cue/' .. NamedControl.GetText("CueCode3"), 'i', { loopCount } ))
        NamedControl.SetValue("PlayCue3", 0)
    end

    state = NamedControl.GetValue("PlayCue4")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/cue/' .. NamedControl.GetText("CueCode4"), 'i', { loopCount } ))
        NamedControl.SetValue("PlayCue4", 0)
    end

    state = NamedControl.GetValue("PlayCue5")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/cue/' .. NamedControl.GetText("CueCode5"), 'i', { loopCount } ))
        NamedControl.SetValue("PlayCue5", 0)
    end

    state = NamedControl.GetValue("PlayCue6")
    if state == 1 and SendUpdates then
        print("Sending UDP Message to " .. IP)
        OscSocket:Send(IP, port, oscPacket('/dmxcore/cue/' .. NamedControl.GetText("CueCode6"), 'i', { loopCount } ))
        NamedControl.SetValue("PlayCue6", 0)
    end

    SendUpdates = true
end

MainTimer = Timer.New()
MainTimer.EventHandler = MainTimerCallback
MainTimer:Start(.25)

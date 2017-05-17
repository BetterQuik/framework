--------------------------------------------------------------------------------
-- BetterQuik - intraday trading framework
--
-- © 2017 Denis Kolodin
--------------------------------------------------------------------------------

ENGINE_VERSION = "7.0.0"

BASE_PATH = getScriptPath().."\\"

math.randomseed(os.time() + os.clock()) -- Random ID guarantee

-- SERVICE FUNCTIONS

function table.reverse(tab)
	local size = #tab
	local ntab = {}
	for i, v in ipairs(tab) do
		ntab[size-i+1] = v
	end
	return ntab
end

function table.transform(tab, felem)
	local ntab = {}
	for idx = 1, #tab do
		ntab[idx] = felem(tab[idx])
	end
	return ntab
end

function round(num, idp)
	local mult = 10 ^ (idp or 0)
	return math.floor(num * mult + 0.5) / mult
end

function split_delim(str, delim)
	if str == "" then return {} end
	local result = {}
	local append = delim
	if delim:match("%%") then
		append = delim:gsub("%%", "")
	end
	for match in (str .. append):gmatch("(.-)" .. delim) do
		table.insert(result, match)
	end
	return result
end

function split_names(s)
	local result = {}
	for k, v in string.gmatch(s, "[%w_]+") do
		table.insert(result, k)
	end
	return result
end

-- Unique identifier for keys to unique identify stocks
local function MTID(market, ticker)
	return market..":"..ticker
end

function GetMarkets()
	return split_names(getClassesList())
end

function GetTickers(market)
	return split_names(getClassSecurities(market))
end

function GetClientCodes()
	local result = {}
	local total = getNumberOf("client_codes")
	for idx = 0, total-1 do
		local code = getItem("client_codes", idx)
		table.insert(result, code)
	end
	return result
end

function GetClientAccounts()
	local result = {}
	local total = getNumberOf("trade_accounts")
	for idx = 0, total-1 do
		local row = getItem("trade_accounts", idx)
		table.insert(result, row.trdaccid)
	end
	return result
end

-- OBJECT HIERARCHY PATCH

OOP = {}
function OOP.Class(class)
	local constructor_meta = {
		__call = function(class, instance)
			local indexer_meta = {
				__index = class.indexer or class
			}
			setmetatable(instance, indexer_meta)
			if (class.constructor ~= nil) then
				class.constructor(instance)
			end
			return instance
		end
	}
	setmetatable(class, constructor_meta)
	return class
end

-- LOGGING

Log = OOP.Class {
	logfile = nil,
	loglevel = 0,
	loglevels = {
		[-1] = 'Debug',
		[ 0] = 'Trace',
		[ 1] = 'Info',
		[ 2] = 'Warning',
		[ 3] = 'Error',
	},
	logtime = 0,
	logwaterline = 20,  -- Messages
	logthrottling = 10, -- Seconds
}
function Log:log(log_table, log_level)
	if type(log_table) == "string" then
		message(log_table, 3)
	end
	for idx = 1, #log_table do
		log_table[idx] = tostring(log_table[idx])
	end
	local log_text = table.concat(log_table, " ")
	if (log_level >= self.loglevel) then
		local now = os.clock()
		if (now > self.logtime) then
			self.logtime = now + self.logthrottling
			self.logrecorder = {}
			self.logcounter = 0
		end
		if ((self.logcounter <= self.logwaterline) and (self.logrecorder[log_text] == nil)) then
			self.logrecorder[log_text] = true
			self.logcounter = self.logcounter + 1

			local msg = string.format("[%s] %s: %s\n", os.date(), self.loglevels[log_level], log_text)
			if (log_level > 0) then
				message(msg, log_level)
			elseif (log_level == -1) then
				PrintDbgStr(msg)
			end
			-- nil if you create object before OnInit called
			if (self.logfile ~= nil) then
				self.logfile:write(msg)
				self.logfile:flush()
			end
		end
	end
	return log_text
end
function Log:table(prefix, t)
	local parts = {}

	table.insert(parts, prefix)
	table.insert(parts, " {")
	for i,v in ipairs(t) do
		table.insert(parts, tostring(i))
		table.insert(parts, "=")
		table.insert(parts, tostring(v))
		table.insert(parts, ", ")
	end
	for k,v in pairs(t) do
		table.insert(parts, tostring(k))
		table.insert(parts, "=")
		table.insert(parts, tostring(v))
		table.insert(parts, ", ")
	end
	table.insert(parts, "} ")

	t = table.concat(parts, "")
	self:log(t, 0)
end
function Log:debug(...)
	self:log({...}, -1)
end
function Log:trace(...)
	self:log({...}, 0)
end
function Log:info(...)
	self:log({...}, 1)
end
function Log:warning(...)
	self:log({...}, 2)
end
function Log:error(...)
	self:log({...}, 3)
end
function Log:fatal(...)
	local msg = self:log({...}, 3)
	error(msg, 4)
end
-- Create global logger
log = Log {}

-- EXECUTION SUBSYSTEM
ProcessingPool = {}
local function Register(instance, method)
	ProcessingPool[instance] = method
end
local function Unregister(instance)
	ProcessingPool[instance] = nil
end
local function ProcessRegistered()
	for instance,method in pairs(ProcessingPool) do
		method(instance)
		sleep(1)
	end
end

AtExitPool = {}
function AtExit(hook)
	table.insert(AtExitPool, hook)
end
local function ProcessAtExit()
	local hook = table.remove(AtExitPool)
	while (hook ~= nil) do
		hook()
		hook = table.remove(AtExitPool)
	end
end


Trig = OOP.Class{}
function Trig:constructor()
	if (self.line == nil) then
		log:error("Trigger level not set.")
	end
end
function Trig:update(new_line)
	if self.reverse then
		self.line = math.min(self.line, new_line)
	else
		self.line = math.max(self.line, new_line)
	end
end
function Trig:check(value)
	self.remain = value - self.line
	if self.reverse then
		return value > self.line
	else
		return value < self.line
	end
end

CallBarrier = OOP.Class{}
function CallBarrier:constructor()
	self.trigger = Trig{line=os.clock(), reverse=false}
end
function CallBarrier:maybe_call()
	if (not self.trigger:check(os.clock() - self.interval)) then
		self.trigger:update(os.clock())
		return true, self.routine()
	else
		return false, nil
	end
end

QuoteSubscribtions = OOP.Class{}
function QuoteSubscribtions:constructor()
	self.pool = {}
end
function QuoteSubscribtions:subscribe(market, ticker)
	local id = MTID(market, ticker)
	local counter = self.pool[id]
	if (counter == nil) then
		self.pool[id] = 1
	else
		self.pool[id] = counter + 1
	end
	if (not IsSubscribed_Level_II_Quotes(market, ticker)) then
		log:debug("Subscribed to quotes "..id)
		Subscribe_Level_II_Quotes(market, ticker)
	end
end
function QuoteSubscribtions:unsubscribe(market, ticker)
	local id = MTID(market, ticker)
	local counter = self.pool[id]
	if (counter ~= nil) then
		counter = counter - 1
		if (counter < 0) then
			log:warning("Quotes unsubscribed more than subscribed")
			counter = 0
		end
		self.pool[id] = counter
	end
	if (counter == 0) then
		log:debug("Unsubscribed from quotes "..id)
		Unsubscribe_Level_II_Quotes(market, ticker)
	end
end

local QUOTE_SUBS = QuoteSubscribtions{}

--[[ MARKET DATA SOURCE ]]--
MarketData = OOP.Class{}
function MarketData._pvconverter(elem)
	local nelem = {}
	nelem.price = tonumber(elem.price)
	nelem.volume = tonumber(elem.volume)
	return nelem
end
function MarketData:constructor()
	if rawget(self, "market") == nil then
		log:fatal("Market not defined.")
	end
	if rawget(self, "ticker") == nil then
		log:fatal("Ticker not defined.")
	end
	QUOTE_SUBS:subscribe(self.market, self.ticker)
	log:trace("MarketData created: " .. self.market .. " " .. self.ticker)
end
function MarketData:indexer(key)
	if MarketData[key] ~= nil then
		return MarketData[key]
	end
	if key == "bids" then
		local data = getQuoteLevel2(self.market, self.ticker).bid
		if (data == nil) then
			return nil
		end
		data = table.reverse(data) -- Reverse for normal order (not alphabet)!
		data = table.transform(data, self._pvconverter)
		return data or {}
	elseif key == "offers" then
		local data = getQuoteLevel2(self.market, self.ticker).offer
		if (data == nil) then
			return nil
		end
		data = table.transform(data, self._pvconverter)
		return data or {}
	end
	local param = getParamEx(self.market, self.ticker, key)
	if tonumber(param.param_type) < 3 then
		return tonumber(param.param_value)
	else
		return param.param_value
	end
end
function MarketData:fit(price)
	local step = self.sec_price_step
	local result = math.floor(price / step) * step
	return round(result, self.sec_scale)
end
function MarketData:move(price, val)
	local step = self.sec_price_step
	local result = (math.floor(price / step) * step) + (val * step)
	result = round(result, self.sec_scale)
	-- log:info(price, val, self.sec_price_step, self.sec_scale, result)
	return result
end
function MarketData:destroy()
	QUOTE_SUBS:unsubscribe(self.market, self.ticker)
end

--[[ EXECUTION SYSTEM ]]--
local FloodControl = {
	tps = 2,
	counter = 0,
	interval = 1.11,
	resettime = 0,
}
local function NoFloodTransaction(t)
	local now = os.clock()
	if (now > FloodControl.resettime) then
		FloodControl.resettime = now + FloodControl.interval
		FloodControl.counter = FloodControl.tps
	end
	if (FloodControl.counter > 0) then
		FloodControl.counter = FloodControl.counter - 1
		return sendTransaction(t)
	else
		return "transactions limit exceed"
	end
end

function seconds_of_day()
	local s = getInfoParam("LOCALTIME")
	local result = 0
	local muls = {1, 60, 60*60}
	for n in string.gmatch(s, "%d+") do
		local mul = table.remove(muls)
		result = result + tonumber(n) * mul
	end
	return result
end

local function create_idpool()
	local result_pool = {}
	local pool_base = seconds_of_day() * 1000
	local pool_min = pool_base + 1
	local pool_max = pool_base + 999
	log:debug("Pool bounds:", pool_min, pool_max)
	for id = pool_min, pool_max do
		table.insert(result_pool, id)
	end
	return result_pool
end
SmartOrder = OOP.Class {
	pool = {},
}
function SmartOrder:indexer(key)
	-- TODO Maybe make a metamethod to prevent infinite recursion
	if SmartOrder[key] ~= nil then
		return SmartOrder[key]
	end
	-- Dynamic fields have to be calculated!
	if key == "remainder" then
		return (self.planned - self.position)
	end
	if key == "filled" then
		return math.abs(self.position)
	end
	if key == "active" then
		return (self.order ~= nil) and self.order.active
	end
	if key == "done" then
		if (self.order ~= nil) then
			return false
		else
			return (self.planned - self.position) == 0
		end
	end
	return nil
end
function SmartOrder:constructor()
	if (#IDPool < 1) then
		log:fatal("Orders limit exceed!")
	end
	local key = table.remove(IDPool, 1)
	SmartOrder.pool[key] = self
	self.trans_id = key

	self.position = 0
	self.planned = 0
	self.order = nil
	self.trades = {}
	self.price_stat = {
		enter_sum = 0, enter_count = 0,
		exit_sum = 0, exit_count = 0,
	}
	log:trace("SmartOrder created with trans_id: " .. self.trans_id)
	Register(self, SmartOrder.process)
end
function SmartOrder:destroy()
	Unregister(self)
	SmartOrder.pool[self.trans_id] = nil
	table.insert(IDPool, self.trans_id)
end
function SmartOrder:process_trade(qnt, prc, sell)
	local stat = self.price_stat
	if not sell then
		stat.enter_sum = stat.enter_sum + (qnt * prc)
		stat.enter_count = stat.enter_count + qnt
	else
		stat.exit_sum = stat.exit_sum + (qnt * prc)
		stat.exit_count = stat.exit_count + qnt
	end
end
function SmartOrder:price_balance(market_price)
	local stat = self.price_stat
	local simulated = market_price * (stat.enter_count - stat.exit_count)
	return stat.exit_sum - stat.enter_sum + simulated
end
function SmartOrder:update(price, planned)
	if price ~= nil then
		self.price = price
	end
	if planned ~= nil then
		self.planned = planned
	end
end
function SmartOrder:enough()
	self.planned = self.position
end
function SmartOrder:process()
	log:debug("Processing SmartOrder " .. self.trans_id)
	local order = self.order
	if order ~= nil then
		local cancel = false
		if order.price ~= self.price then
			cancel = true
		end
		local filled = order.filled * order.sign
		if self.planned - self.position - order.quantity ~= 0 then
			cancel = true
		end
		if order.active == false then
			-- Calculate when flag was set!!!
			filled = order.filled * order.sign
			self.position = self.position + filled
			self.order = nil
		else
			if cancel then
				if self.order.number ~= nil then
					if self.order.cancelled ~= nil then
						if (os.time() - self.order.cancelled) > 5 then
							self.order.cancelled = nil
						end
					else
						local result = NoFloodTransaction{
							ACCOUNT=self.account,
							CLIENT_CODE=self.client,
							CLASSCODE=self.market,
							SECCODE=self.ticker,
							TRANS_ID=tostring(666), -- WARNING!
							-- Never mind it as real send order transaction and set unique id,
							-- because quantity calculation colission possible!
							ACTION="KILL_ORDER",
							ORDER_KEY=tostring(self.order.number)
						}
						if result == "" then
							self.order.cancelled = os.time()
						end
						log:debug("Kill order")
					end
				end
			end
		end
	else
		local diff = self.planned - self.position
		if diff ~= 0 then
			if (self.order == nil and self.price ~= nil) then
				local absdiff = math.abs(diff)
				self.order = {
					sign = diff / absdiff,
					price = self.price,
					quantity = diff,
					active = true,
					filled = 0,
				}
				local result = NoFloodTransaction{
					ACCOUNT=self.account,
					CLIENT_CODE=self.client,
					CLASSCODE=self.market,
					SECCODE=self.ticker,
					TYPE="L",
					TRANS_ID=tostring(self.trans_id),
					ACTION="NEW_ORDER",
					OPERATION=(diff > 0 and "B") or "S",
					PRICE=tostring(self.price),
					QUANTITY=tostring(absdiff)
				}
				if result ~= "" then
					log:warning("Can't put order because of ", result)
					self.order = nil
				end
				log:debug("Kill order")
			end
		end
	end
	local oderstatus = "Unknown"
	if (self.order == nil) then
		oderstatus = "Not attached"
	else
		if (self.order.number == nil) then
			oderstatus = "Not defined"
		else
			oderstatus = tostring(self.order.number)
		end
	end
end

--[[ MAIN LOOP ]]--
Trade = coroutine.yield
WORKING_FLAG = true
function OnMain()
	local fatal = nil
	log:trace("Robot started")
	if Start ~= nil then
		Start()
	end
	-- Auto stop orders
	AtExit(function()
		for _,so in pairs(SmartOrder.pool) do
			so:enough()
			so:process()
		end
	end)
	if Robot ~= nil then
		local routine = coroutine.create(Robot)
		while WORKING_FLAG do
			local res, errmsg = coroutine.resume(routine)
			if res == false then
				fatal = "Broken coroutine: " .. errmsg
				log:error(fatal)
				break
			end
			if coroutine.status(routine) == "dead" then
				log:trace("Robot routine finished")
				break
			end
			ProcessRegistered()
			sleep(5)
		end
	end
	ProcessAtExit()
	if Stop ~= nil then
		Stop()
	end
	log:trace("Robot stopped")
	-- Because main can write after OnStop callback
	if (log.logfile ~= nil) then
		io.close(log.logfile)
	end
	if (fatal ~= nil) then
		error(fatal)
	end
end


FileAssist = OOP.Class{}
function FileAssist:constructor()
	-- Check path
	-- Check name
end
function FileAssist:get_path(data)
	return BASE_PATH..self.name
end
function FileAssist:save(data)
	-- TODO Generate path dinamically
	local file = io.open(self:get_path(), 'w')
	if (file == nil) then
		log:fatal("Íåâîçìîæíî ñîõðàíèòü ôàéë!")
	else
		file:write(data)
		file:close()
	end
end
function FileAssist:read()
	local file = io.open(self:get_path(), 'r')
	if (file ~= nil) then
		local data = file:read("*all")
		file:close()
		return data
	end
end
function FileAssist:delete()
	os.remove(self:get_path())
end

--[[ INIT CALLBACK ]]--
IDPool = {} -- empty pool as start
Config = nil
function OnInit(path)
	-- Open log file
	local spath = getScriptPath()
	local _start = string.len(spath) + 2
	local _end = string.len(path) - 4
	local partition = string.sub(path, _start, _end)
	local fname = partition.."-"..os.date("%Y%m%d-%H%M%S")..".log"
	local log_path = BASE_PATH.."\\..\\log\\"..fname
	log.logfile = io.open(log_path, 'a')
	if (log.logfile == nil) then
		log:fatal("Can't create logging file.")
	end

	-- Read TOML
	local toml_path = spath.."\\..\\config\\"..partition..".toml"
	local toml, msg = io.open(toml_path, "r")
	if (toml == nil) then
		log:fatal("Error with config:", msg)
	end
	local toml_data = toml:read("*a")
	toml:close()

	local config = TOML.parse(toml_data)
	Config = config[partition]
	if (Config == nil) then
		log:fatal("No config for", "["..partition.."]", "in", toml_path)
	end

	IDPool = create_idpool()
end

--[[ TRANSACTION CALLBACK ]]--
function OnTransReply(trans_reply)
	-- «0» - òðàíçàêöèÿ îòïðàâëåíà ñåðâåðó
	-- «1» - òðàíçàêöèÿ ïîëó÷åíà íà ñåðâåð QUIK îò êëèåíòà
	-- «2» - îøèáêà ïðè ïåðåäà÷å òðàíçàêöèè â òîðãîâóþ ñèñòåìó, ïîñêîëüêó îòñóòñòâóåò ïîäêëþ÷åíèå øëþçà Ìîñêîâñêîé Áèðæè, ïîâòîðíî òðàíçàêöèÿ íå îòïðàâëÿåòñÿ
	-- «3» - òðàíçàêöèÿ âûïîëíåíà
	-- «4» - òðàíçàêöèÿ íå âûïîëíåíà òîðãîâîé ñèñòåìîé, êîä îøèáêè òîðãîâîé ñèñòåìû áóäåò óêàçàí â ïîëå «DESCRIPTION»
	-- «5» - òðàíçàêöèÿ íå ïðîøëà ïðîâåðêó ñåðâåðà QUIK ïî êàêèì-ëèáî êðèòåðèÿì. Íàïðèìåð, ïðîâåðêó íà íàëè÷èå ïðàâ ó ïîëüçîâàòåëÿ íà îòïðàâêó òðàíçàêöèè äàííîãî òèïà
	-- «6» - òðàíçàêöèÿ íå ïðîøëà ïðîâåðêó ëèìèòîâ ñåðâåðà QUIK
	-- «10» - òðàíçàêöèÿ íå ïîääåðæèâàåòñÿ òîðãîâîé ñèñòåìîé. Ê ïðèìåðó, ïîïûòêà îòïðàâèòü «ACTION = MOVE_ORDERS» íà Ìîñêîâñêîé Áèðæå
	-- «11» - òðàíçàêöèÿ íå ïðîøëà ïðîâåðêó ïðàâèëüíîñòè ýëåêòðîííîé ïîäïèñè. Ê ïðèìåðó, åñëè êëþ÷è, çàðåãèñòðèðîâàííûå íà ñåðâåðå, íå ñîîòâåòñòâóþò ïîäïèñè îòïðàâëåííîé òðàíçàêöèè
	-- «12» - íå óäàëîñü äîæäàòüñÿ îòâåòà íà òðàíçàêöèþ, ò.ê. èñòåê òàéìàóò îæèäàíèÿ. Ìîæåò âîçíèêíóòü ïðè ïîäà÷å òðàíçàêöèé èç QPILE
	-- «13» - òðàíçàêöèÿ îòâåðãíóòà, ò.ê. åå âûïîëíåíèå ìîãëî ïðèâåñòè ê êðîññ-ñäåëêå (ò.å. ñäåëêå ñ òåì æå ñàìûì êëèåíòñêèì ñ÷åòîì)
	local key = trans_reply.trans_id
	local executor = SmartOrder.pool[key]
	if (executor ~= nil) then
		if (executor.order ~= nil) then
			if trans_reply.status == 3 then
				executor.order.number = trans_reply.order_num
			else
				executor.order = nil
			end
		else
			log:warning("Error with transaction", key)
		end
	end
end

local quantity_total = 0

--[[ ORDERS CALLBACK ]]--
function OnOrder(order)
	local key = order.trans_id
	local executor = SmartOrder.pool[key]
	-- There isn't order if was executed imidiately!
	if executor ~= nil and executor.order ~= nil then
		local prev_filled = executor.order.filled
		local new_filled = order.qty - order.balance
		executor.order.filled = new_filled
		if bit.band(order.flags, 0x1) == 0 then
			executor.order.active = false
		end
		local trade_qnt = new_filled - prev_filled
		if (trade_qnt > 0) then
			local trade_prc = order.price
			local trade_sell = bit.band(order.flags, 0x4) == 0x4

			if trade_sell then
				quantity_total = quantity_total - trade_qnt
			else
				quantity_total = quantity_total + trade_qnt
			end
			--log:warning("Quantity "..tostring(quantity_total))

			executor:process_trade(trade_qnt, trade_prc, trade_sell)
		end
	end
end



--[[ END CALLBACK ]]--
function OnStop(stop_flag)
	WORKING_FLAG = false
	ProcessAtExit()
	return 7000
end

function main()
	OnMain()
end

function Terminate()
	WORKING_FLAG = false
end


--[[
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
]]--

--------------------------------------------------------------------------------
-- MODULE: JSON
--------------------------------------------------------------------------------

local json_module_creator = function()
	-- -*- coding: utf-8 -*-
	--
	-- Simple JSON encoding and decoding in pure Lua.
	--
	-- Copyright 2010-2014 Jeffrey Friedl
	-- http://regex.info/blog/
	--
	-- Latest version: http://regex.info/blog/lua/json
	--
	-- This code is released under a Creative Commons CC-BY "Attribution" License:
	-- http://creativecommons.org/licenses/by/3.0/deed.en_US
	--
	-- It can be used for any purpose so long as the copyright notice above,
	-- the web-page links above, and the 'AUTHOR_NOTE' string below are
	-- maintained. Enjoy.
	--
	local VERSION = 20141223.14 -- version history at end of file
	local AUTHOR_NOTE = "-[ JSON.lua package by Jeffrey Friedl (http://regex.info/blog/lua/json) version 20141223.14 ]-"

	--
	-- The 'AUTHOR_NOTE' variable exists so that information about the source
	-- of the package is maintained even in compiled versions. It's also
	-- included in OBJDEF below mostly to quiet warnings about unused variables.
	--
	local OBJDEF = {
		VERSION      = VERSION,
		AUTHOR_NOTE  = AUTHOR_NOTE,
	}


	--
	-- Simple JSON encoding and decoding in pure Lua.
	-- http://www.json.org/
	--
	--
	--   JSON = assert(loadfile "JSON.lua")() -- one-time load of the routines
	--
	--   local lua_value = JSON:decode(raw_json_text)
	--
	--   local raw_json_text    = JSON:encode(lua_table_or_value)
	--   local pretty_json_text = JSON:encode_pretty(lua_table_or_value) -- "pretty printed" version for human readability
	--
	--
	--
	-- DECODING (from a JSON string to a Lua table)
	--
	--
	--   JSON = assert(loadfile "JSON.lua")() -- one-time load of the routines
	--
	--   local lua_value = JSON:decode(raw_json_text)
	--
	--   If the JSON text is for an object or an array, e.g.
	--     { "what": "books", "count": 3 }
	--   or
	--     [ "Larry", "Curly", "Moe" ]
	--
	--   the result is a Lua table, e.g.
	--     { what = "books", count = 3 }
	--   or
	--     { "Larry", "Curly", "Moe" }
	--
	--
	--   The encode and decode routines accept an optional second argument,
	--   "etc", which is not used during encoding or decoding, but upon error
	--   is passed along to error handlers. It can be of any type (including nil).
	--
	--
	--
	-- ERROR HANDLING
	--
	--   With most errors during decoding, this code calls
	--
	--      JSON:onDecodeError(message, text, location, etc)
	--
	--   with a message about the error, and if known, the JSON text being
	--   parsed and the byte count where the problem was discovered. You can
	--   replace the default JSON:onDecodeError() with your own function.
	--
	--   The default onDecodeError() merely augments the message with data
	--   about the text and the location if known (and if a second 'etc'
	--   argument had been provided to decode(), its value is tacked onto the
	--   message as well), and then calls JSON.assert(), which itself defaults
	--   to Lua's built-in assert(), and can also be overridden.
	--
	--   For example, in an Adobe Lightroom plugin, you might use something like
	--
	--          function JSON:onDecodeError(message, text, location, etc)
	--             LrErrors.throwUserError("Internal Error: invalid JSON data")
	--          end
	--
	--   or even just
	--
	--          function JSON.assert(message)
	--             LrErrors.throwUserError("Internal Error: " .. message)
	--          end
	--
	--   If JSON:decode() is passed a nil, this is called instead:
	--
	--      JSON:onDecodeOfNilError(message, nil, nil, etc)
	--
	--   and if JSON:decode() is passed HTML instead of JSON, this is called:
	--
	--      JSON:onDecodeOfHTMLError(message, text, nil, etc)
	--
	--   The use of the fourth 'etc' argument allows stronger coordination
	--   between decoding and error reporting, especially when you provide your
	--   own error-handling routines. Continuing with the the Adobe Lightroom
	--   plugin example:
	--
	--          function JSON:onDecodeError(message, text, location, etc)
	--             local note = "Internal Error: invalid JSON data"
	--             if type(etc) = 'table' and etc.photo then
	--                note = note .. " while processing for " .. etc.photo:getFormattedMetadata('fileName')
	--             end
	--             LrErrors.throwUserError(note)
	--          end
	--
	--            :
	--            :
	--
	--          for i, photo in ipairs(photosToProcess) do
	--               :
	--               :
	--               local data = JSON:decode(someJsonText, { photo = photo })
	--               :
	--               :
	--          end
	--
	--
	--
	--
	--
	-- DECODING AND STRICT TYPES
	--
	--   Because both JSON objects and JSON arrays are converted to Lua tables,
	--   it's not normally possible to tell which original JSON type a
	--   particular Lua table was derived from, or guarantee decode-encode
	--   round-trip equivalency.
	--
	--   However, if you enable strictTypes, e.g.
	--
	--      JSON = assert(loadfile "JSON.lua")() --load the routines
	--      JSON.strictTypes = true
	--
	--   then the Lua table resulting from the decoding of a JSON object or
	--   JSON array is marked via Lua metatable, so that when re-encoded with
	--   JSON:encode() it ends up as the appropriate JSON type.
	--
	--   (This is not the default because other routines may not work well with
	--   tables that have a metatable set, for example, Lightroom API calls.)
	--
	--
	-- ENCODING (from a lua table to a JSON string)
	--
	--   JSON = assert(loadfile "JSON.lua")() -- one-time load of the routines
	--
	--   local raw_json_text    = JSON:encode(lua_table_or_value)
	--   local pretty_json_text = JSON:encode_pretty(lua_table_or_value) -- "pretty printed" version for human readability
	--   local custom_pretty    = JSON:encode(lua_table_or_value, etc, { pretty = true, indent = "|  ", align_keys = false })
	--
	--   On error during encoding, this code calls:
	--
	--     JSON:onEncodeError(message, etc)
	--
	--   which you can override in your local JSON object.
	--
	--   The 'etc' in the error call is the second argument to encode()
	--   and encode_pretty(), or nil if it wasn't provided.
	--
	--
	-- PRETTY-PRINTING
	--
	--   An optional third argument, a table of options, allows a bit of
	--   configuration about how the encoding takes place:
	--
	--     pretty = JSON:encode(val, etc, {
	--                                       pretty = true,      -- if false, no other options matter
	--                                       indent = "   ",     -- this provides for a three-space indent per nesting level
	--                                       align_keys = false, -- see below
	--                                     })
	--
	--   encode() and encode_pretty() are identical except that encode_pretty()
	--   provides a default options table if none given in the call:
	--
	--       { pretty = true, align_keys = false, indent = "  " }
	--
	--   For example, if
	--
	--      JSON:encode(data)
	--
	--   produces:
	--
	--      {"city":"Kyoto","climate":{"avg_temp":16,"humidity":"high","snowfall":"minimal"},"country":"Japan","wards":11}
	--
	--   then
	--
	--      JSON:encode_pretty(data)
	--
	--   produces:
	--
	--      {
	--        "city": "Kyoto",
	--        "climate": {
	--          "avg_temp": 16,
	--          "humidity": "high",
	--          "snowfall": "minimal"
	--        },
	--        "country": "Japan",
	--        "wards": 11
	--      }
	--
	--   The following three lines return identical results:
	--       JSON:encode_pretty(data)
	--       JSON:encode_pretty(data, nil, { pretty = true, align_keys = false, indent = "  " })
	--       JSON:encode       (data, nil, { pretty = true, align_keys = false, indent = "  " })
	--
	--   An example of setting your own indent string:
	--
	--     JSON:encode_pretty(data, nil, { pretty = true, indent = "|    " })
	--
	--   produces:
	--
	--      {
	--      |    "city": "Kyoto",
	--      |    "climate": {
	--      |    |    "avg_temp": 16,
	--      |    |    "humidity": "high",
	--      |    |    "snowfall": "minimal"
	--      |    },
	--      |    "country": "Japan",
	--      |    "wards": 11
	--      }
	--
	--   An example of setting align_keys to true:
	--
	--     JSON:encode_pretty(data, nil, { pretty = true, indent = "  ", align_keys = true })
	--
	--   produces:
	--
	--      {
	--           "city": "Kyoto",
	--        "climate": {
	--                     "avg_temp": 16,
	--                     "humidity": "high",
	--                     "snowfall": "minimal"
	--                   },
	--        "country": "Japan",
	--          "wards": 11
	--      }
	--
	--   which I must admit is kinda ugly, sorry. This was the default for
	--   encode_pretty() prior to version 20141223.14.
	--
	--
	--  AMBIGUOUS SITUATIONS DURING THE ENCODING
	--
	--   During the encode, if a Lua table being encoded contains both string
	--   and numeric keys, it fits neither JSON's idea of an object, nor its
	--   idea of an array. To get around this, when any string key exists (or
	--   when non-positive numeric keys exist), numeric keys are converted to
	--   strings.
	--
	--   For example,
	--     JSON:encode({ "one", "two", "three", SOMESTRING = "some string" }))
	--   produces the JSON object
	--     {"1":"one","2":"two","3":"three","SOMESTRING":"some string"}
	--
	--   To prohibit this conversion and instead make it an error condition, set
	--      JSON.noKeyConversion = true
	--




	--
	-- SUMMARY OF METHODS YOU CAN OVERRIDE IN YOUR LOCAL LUA JSON OBJECT
	--
	--    assert
	--    onDecodeError
	--    onDecodeOfNilError
	--    onDecodeOfHTMLError
	--    onEncodeError
	--
	--  If you want to create a separate Lua JSON object with its own error handlers,
	--  you can reload JSON.lua or use the :new() method.
	--
	---------------------------------------------------------------------------

	local default_pretty_indent  = "  "
	local default_pretty_options = { pretty = true, align_keys = false, indent = default_pretty_indent }

	local isArray  = { __tostring = function() return "JSON array"  end }    isArray.__index  = isArray
	local isObject = { __tostring = function() return "JSON object" end }    isObject.__index = isObject


	function OBJDEF:newArray(tbl)
		return setmetatable(tbl or {}, isArray)
	end

	function OBJDEF:newObject(tbl)
		return setmetatable(tbl or {}, isObject)
	end

	local function unicode_codepoint_as_utf8(codepoint)
		--
		-- codepoint is a number
		--
		if codepoint <= 127 then
			return string.char(codepoint)

		elseif codepoint <= 2047 then
			--
			-- 110yyyxx 10xxxxxx         <-- useful notation from http://en.wikipedia.org/wiki/Utf8
			--
			local highpart = math.floor(codepoint / 0x40)
			local lowpart  = codepoint - (0x40 * highpart)
			return string.char(0xC0 + highpart,
			0x80 + lowpart)

		elseif codepoint <= 65535 then
			--
			-- 1110yyyy 10yyyyxx 10xxxxxx
			--
			local highpart  = math.floor(codepoint / 0x1000)
			local remainder = codepoint - 0x1000 * highpart
			local midpart   = math.floor(remainder / 0x40)
			local lowpart   = remainder - 0x40 * midpart

			highpart = 0xE0 + highpart
			midpart  = 0x80 + midpart
			lowpart  = 0x80 + lowpart

			--
			-- Check for an invalid character (thanks Andy R. at Adobe).
			-- See table 3.7, page 93, in http://www.unicode.org/versions/Unicode5.2.0/ch03.pdf#G28070
			--
			if ( highpart == 0xE0 and midpart < 0xA0 ) or
				( highpart == 0xED and midpart > 0x9F ) or
				( highpart == 0xF0 and midpart < 0x90 ) or
				( highpart == 0xF4 and midpart > 0x8F )
				then
					return "?"
				else
					return string.char(highpart,
					midpart,
					lowpart)
				end

			else
				--
				-- 11110zzz 10zzyyyy 10yyyyxx 10xxxxxx
				--
				local highpart  = math.floor(codepoint / 0x40000)
				local remainder = codepoint - 0x40000 * highpart
				local midA      = math.floor(remainder / 0x1000)
				remainder       = remainder - 0x1000 * midA
				local midB      = math.floor(remainder / 0x40)
				local lowpart   = remainder - 0x40 * midB

				return string.char(0xF0 + highpart,
				0x80 + midA,
				0x80 + midB,
				0x80 + lowpart)
			end
		end

		function OBJDEF:onDecodeError(message, text, location, etc)
			if text then
				if location then
					message = string.format("%s at char %d of: %s", message, location, text)
				else
					message = string.format("%s: %s", message, text)
				end
			end

			if etc ~= nil then
				message = message .. " (" .. OBJDEF:encode(etc) .. ")"
			end

			if self.assert then
				self.assert(false, message)
			else
				assert(false, message)
			end
		end

		OBJDEF.onDecodeOfNilError  = OBJDEF.onDecodeError
		OBJDEF.onDecodeOfHTMLError = OBJDEF.onDecodeError

		function OBJDEF:onEncodeError(message, etc)
			if etc ~= nil then
				message = message .. " (" .. OBJDEF:encode(etc) .. ")"
			end

			if self.assert then
				self.assert(false, message)
			else
				assert(false, message)
			end
		end

		local function grok_number(self, text, start, etc)
			--
			-- Grab the integer part
			--
			local integer_part = text:match('^-?[1-9]%d*', start)
			or text:match("^-?0",        start)

			if not integer_part then
				self:onDecodeError("expected number", text, start, etc)
			end

			local i = start + integer_part:len()

			--
			-- Grab an optional decimal part
			--
			local decimal_part = text:match('^%.%d+', i) or ""

			i = i + decimal_part:len()

			--
			-- Grab an optional exponential part
			--
			local exponent_part = text:match('^[eE][-+]?%d+', i) or ""

			i = i + exponent_part:len()

			local full_number_text = integer_part .. decimal_part .. exponent_part
			local as_number = tonumber(full_number_text)

			if not as_number then
				self:onDecodeError("bad number", text, start, etc)
			end

			return as_number, i
		end


		local function grok_string(self, text, start, etc)

			if text:sub(start,start) ~= '"' then
				self:onDecodeError("expected string's opening quote", text, start, etc)
			end

			local i = start + 1 -- +1 to bypass the initial quote
			local text_len = text:len()
			local VALUE = ""
			while i <= text_len do
				local c = text:sub(i,i)
				if c == '"' then
					return VALUE, i + 1
				end
				if c ~= '\\' then
					VALUE = VALUE .. c
					i = i + 1
				elseif text:match('^\\b', i) then
					VALUE = VALUE .. "\b"
					i = i + 2
				elseif text:match('^\\f', i) then
					VALUE = VALUE .. "\f"
					i = i + 2
				elseif text:match('^\\n', i) then
					VALUE = VALUE .. "\n"
					i = i + 2
				elseif text:match('^\\r', i) then
					VALUE = VALUE .. "\r"
					i = i + 2
				elseif text:match('^\\t', i) then
					VALUE = VALUE .. "\t"
					i = i + 2
				else
					local hex = text:match('^\\u([0123456789aAbBcCdDeEfF][0123456789aAbBcCdDeEfF][0123456789aAbBcCdDeEfF][0123456789aAbBcCdDeEfF])', i)
					if hex then
						i = i + 6 -- bypass what we just read

						-- We have a Unicode codepoint. It could be standalone, or if in the proper range and
						-- followed by another in a specific range, it'll be a two-code surrogate pair.
						local codepoint = tonumber(hex, 16)
						if codepoint >= 0xD800 and codepoint <= 0xDBFF then
							-- it's a hi surrogate... see whether we have a following low
							local lo_surrogate = text:match('^\\u([dD][cdefCDEF][0123456789aAbBcCdDeEfF][0123456789aAbBcCdDeEfF])', i)
							if lo_surrogate then
								i = i + 6 -- bypass the low surrogate we just read
								codepoint = 0x2400 + (codepoint - 0xD800) * 0x400 + tonumber(lo_surrogate, 16)
							else
								-- not a proper low, so we'll just leave the first codepoint as is and spit it out.
							end
						end
						VALUE = VALUE .. unicode_codepoint_as_utf8(codepoint)

					else

						-- just pass through what's escaped
						VALUE = VALUE .. text:match('^\\(.)', i)
						i = i + 2
					end
				end
			end

			self:onDecodeError("unclosed string", text, start, etc)
		end

		local function skip_whitespace(text, start)

			local _, match_end = text:find("^[ \n\r\t]+", start) -- [http://www.ietf.org/rfc/rfc4627.txt] Section 2
			if match_end then
				return match_end + 1
			else
				return start
			end
		end

		local grok_one -- assigned later

		local function grok_object(self, text, start, etc)
			if text:sub(start,start) ~= '{' then
				self:onDecodeError("expected '{'", text, start, etc)
			end

			local i = skip_whitespace(text, start + 1) -- +1 to skip the '{'

			local VALUE = self.strictTypes and self:newObject { } or { }

			if text:sub(i,i) == '}' then
				return VALUE, i + 1
			end
			local text_len = text:len()
			while i <= text_len do
				local key, new_i = grok_string(self, text, i, etc)

				i = skip_whitespace(text, new_i)

				if text:sub(i, i) ~= ':' then
					self:onDecodeError("expected colon", text, i, etc)
				end

				i = skip_whitespace(text, i + 1)

				local new_val, new_i = grok_one(self, text, i)

				VALUE[key] = new_val

				--
				-- Expect now either '}' to end things, or a ',' to allow us to continue.
				--
				i = skip_whitespace(text, new_i)

				local c = text:sub(i,i)

				if c == '}' then
					return VALUE, i + 1
				end

				if text:sub(i, i) ~= ',' then
					self:onDecodeError("expected comma or '}'", text, i, etc)
				end

				i = skip_whitespace(text, i + 1)
			end

			self:onDecodeError("unclosed '{'", text, start, etc)
		end

		local function grok_array(self, text, start, etc)
			if text:sub(start,start) ~= '[' then
				self:onDecodeError("expected '['", text, start, etc)
			end

			local i = skip_whitespace(text, start + 1) -- +1 to skip the '['
			local VALUE = self.strictTypes and self:newArray { } or { }
			if text:sub(i,i) == ']' then
				return VALUE, i + 1
			end

			local VALUE_INDEX = 1

			local text_len = text:len()
			while i <= text_len do
				local val, new_i = grok_one(self, text, i)

				-- can't table.insert(VALUE, val) here because it's a no-op if val is nil
				VALUE[VALUE_INDEX] = val
				VALUE_INDEX = VALUE_INDEX + 1

				i = skip_whitespace(text, new_i)

				--
				-- Expect now either ']' to end things, or a ',' to allow us to continue.
				--
				local c = text:sub(i,i)
				if c == ']' then
					return VALUE, i + 1
				end
				if text:sub(i, i) ~= ',' then
					self:onDecodeError("expected comma or '['", text, i, etc)
				end
				i = skip_whitespace(text, i + 1)
			end
			self:onDecodeError("unclosed '['", text, start, etc)
		end


		grok_one = function(self, text, start, etc)
			-- Skip any whitespace
			start = skip_whitespace(text, start)

			if start > text:len() then
				self:onDecodeError("unexpected end of string", text, nil, etc)
			end

			if text:find('^"', start) then
				return grok_string(self, text, start, etc)

			elseif text:find('^[-0123456789 ]', start) then
				return grok_number(self, text, start, etc)

			elseif text:find('^%{', start) then
				return grok_object(self, text, start, etc)

			elseif text:find('^%[', start) then
				return grok_array(self, text, start, etc)

			elseif text:find('^true', start) then
				return true, start + 4

			elseif text:find('^false', start) then
				return false, start + 5

			elseif text:find('^null', start) then
				return nil, start + 4

			else
				self:onDecodeError("can't parse JSON", text, start, etc)
			end
		end

		function OBJDEF:decode(text, etc)
			if type(self) ~= 'table' or self.__index ~= OBJDEF then
				OBJDEF:onDecodeError("JSON:decode must be called in method format", nil, nil, etc)
			end

			if text == nil then
				self:onDecodeOfNilError(string.format("nil passed to JSON:decode()"), nil, nil, etc)
			elseif type(text) ~= 'string' then
				self:onDecodeError(string.format("expected string argument to JSON:decode(), got %s", type(text)), nil, nil, etc)
			end

			if text:match('^%s*$') then
				return nil
			end

			if text:match('^%s*<') then
				-- Can't be JSON... we'll assume it's HTML
				self:onDecodeOfHTMLError(string.format("html passed to JSON:decode()"), text, nil, etc)
			end

			--
			-- Ensure that it's not UTF-32 or UTF-16.
			-- Those are perfectly valid encodings for JSON (as per RFC 4627 section 3),
			-- but this package can't handle them.
			--
			if text:sub(1,1):byte() == 0 or (text:len() >= 2 and text:sub(2,2):byte() == 0) then
				self:onDecodeError("JSON package groks only UTF-8, sorry", text, nil, etc)
			end

			local success, value = pcall(grok_one, self, text, 1, etc)

			if success then
				return value
			else
				-- if JSON:onDecodeError() didn't abort out of the pcall, we'll have received the error message here as "value", so pass it along as an assert.
				if self.assert then
					self.assert(false, value)
				else
					assert(false, value)
				end
				-- and if we're still here, return a nil and throw the error message on as a second arg
				return nil, value
			end
		end

		local function backslash_replacement_function(c)
			if c == "\n" then
				return "\\n"
			elseif c == "\r" then
				return "\\r"
			elseif c == "\t" then
				return "\\t"
			elseif c == "\b" then
				return "\\b"
			elseif c == "\f" then
				return "\\f"
			elseif c == '"' then
				return '\\"'
			elseif c == '\\' then
				return '\\\\'
			else
				return string.format("\\u%04x", c:byte())
			end
		end

		local chars_to_be_escaped_in_JSON_string
		= '['
		..    '"'    -- class sub-pattern to match a double quote
		..    '%\\'  -- class sub-pattern to match a backslash
		..    '%z'   -- class sub-pattern to match a null
		..    '\001' .. '-' .. '\031' -- class sub-pattern to match control characters
		.. ']'

		local function json_string_literal(value)
			local newval = value:gsub(chars_to_be_escaped_in_JSON_string, backslash_replacement_function)
			return '"' .. newval .. '"'
		end

		local function object_or_array(self, T, etc)
			--
			-- We need to inspect all the keys... if there are any strings, we'll convert to a JSON
			-- object. If there are only numbers, it's a JSON array.
			--
			-- If we'll be converting to a JSON object, we'll want to sort the keys so that the
			-- end result is deterministic.
			--
			local string_keys = { }
			local number_keys = { }
			local number_keys_must_be_strings = false
			local maximum_number_key

			for key in pairs(T) do
				if type(key) == 'string' then
					table.insert(string_keys, key)
				elseif type(key) == 'number' then
					table.insert(number_keys, key)
					if key <= 0 or key >= math.huge then
						number_keys_must_be_strings = true
					elseif not maximum_number_key or key > maximum_number_key then
						maximum_number_key = key
					end
				else
					self:onEncodeError("can't encode table with a key of type " .. type(key), etc)
				end
			end

			if #string_keys == 0 and not number_keys_must_be_strings then
				--
				-- An empty table, or a numeric-only array
				--
				if #number_keys > 0 then
					return nil, maximum_number_key -- an array
				elseif tostring(T) == "JSON array" then
					return nil
				elseif tostring(T) == "JSON object" then
					return { }
				else
					-- have to guess, so we'll pick array, since empty arrays are likely more common than empty objects
					return nil
				end
			end

			table.sort(string_keys)

			local map
			if #number_keys > 0 then
				--
				-- If we're here then we have either mixed string/number keys, or numbers inappropriate for a JSON array
				-- It's not ideal, but we'll turn the numbers into strings so that we can at least create a JSON object.
				--

				if self.noKeyConversion then
					self:onEncodeError("a table with both numeric and string keys could be an object or array; aborting", etc)
				end

				--
				-- Have to make a shallow copy of the source table so we can remap the numeric keys to be strings
				--
				map = { }
				for key, val in pairs(T) do
					map[key] = val
				end

				table.sort(number_keys)

				--
				-- Throw numeric keys in there as strings
				--
				for _, number_key in ipairs(number_keys) do
					local string_key = tostring(number_key)
					if map[string_key] == nil then
						table.insert(string_keys , string_key)
						map[string_key] = T[number_key]
					else
						self:onEncodeError("conflict converting table with mixed-type keys into a JSON object: key " .. number_key .. " exists both as a string and a number.", etc)
					end
				end
			end

			return string_keys, nil, map
		end

		--
		-- Encode
		--
		-- 'options' is nil, or a table with possible keys:
		--    pretty            -- if true, return a pretty-printed version
		--    indent            -- a string (usually of spaces) used to indent each nested level
		--    align_keys        -- if true, align all the keys when formatting a table
		--
		local encode_value -- must predeclare because it calls itself
		function encode_value(self, value, parents, etc, options, indent)

			if value == nil then
				return 'null'

			elseif type(value) == 'string' then
				return json_string_literal(value)

			elseif type(value) == 'number' then
				if value ~= value then
					--
					-- NaN (Not a Number).
					-- JSON has no NaN, so we have to fudge the best we can. This should really be a package option.
					--
					return "null"
				elseif value >= math.huge then
					--
					-- Positive infinity. JSON has no INF, so we have to fudge the best we can. This should
					-- really be a package option. Note: at least with some implementations, positive infinity
					-- is both ">= math.huge" and "<= -math.huge", which makes no sense but that's how it is.
					-- Negative infinity is properly "<= -math.huge". So, we must be sure to check the ">="
					-- case first.
					--
					return "1e+9999"
				elseif value <= -math.huge then
					--
					-- Negative infinity.
					-- JSON has no INF, so we have to fudge the best we can. This should really be a package option.
					--
					return "-1e+9999"
				else
					return tostring(value)
				end

			elseif type(value) == 'boolean' then
				return tostring(value)

			elseif type(value) ~= 'table' then
				self:onEncodeError("can't convert " .. type(value) .. " to JSON", etc)

			else
				--
				-- A table to be converted to either a JSON object or array.
				--
				local T = value

				if type(options) ~= 'table' then
					options = {}
				end
				if type(indent) ~= 'string' then
					indent = ""
				end

				if parents[T] then
					self:onEncodeError("table " .. tostring(T) .. " is a child of itself", etc)
				else
					parents[T] = true
				end

				local result_value

				local object_keys, maximum_number_key, map = object_or_array(self, T, etc)
				if maximum_number_key then
					--
					-- An array...
					--
					local ITEMS = { }
					for i = 1, maximum_number_key do
						table.insert(ITEMS, encode_value(self, T[i], parents, etc, options, indent))
					end

					if options.pretty then
						result_value = "[ " .. table.concat(ITEMS, ", ") .. " ]"
					else
						result_value = "["  .. table.concat(ITEMS, ",")  .. "]"
					end

				elseif object_keys then
					--
					-- An object
					--
					local TT = map or T

					if options.pretty then

						local KEYS = { }
						local max_key_length = 0
						for _, key in ipairs(object_keys) do
							local encoded = encode_value(self, tostring(key), parents, etc, options, indent)
							if options.align_keys then
								max_key_length = math.max(max_key_length, #encoded)
							end
							table.insert(KEYS, encoded)
						end
						local key_indent = indent .. tostring(options.indent or "")
						local subtable_indent = key_indent .. string.rep(" ", max_key_length) .. (options.align_keys and "  " or "")
						local FORMAT = "%s%" .. string.format("%d", max_key_length) .. "s: %s"

						local COMBINED_PARTS = { }
						for i, key in ipairs(object_keys) do
							local encoded_val = encode_value(self, TT[key], parents, etc, options, subtable_indent)
							table.insert(COMBINED_PARTS, string.format(FORMAT, key_indent, KEYS[i], encoded_val))
						end
						result_value = "{\n" .. table.concat(COMBINED_PARTS, ",\n") .. "\n" .. indent .. "}"

					else

						local PARTS = { }
						for _, key in ipairs(object_keys) do
							local encoded_val = encode_value(self, TT[key],       parents, etc, options, indent)
							local encoded_key = encode_value(self, tostring(key), parents, etc, options, indent)
							table.insert(PARTS, string.format("%s:%s", encoded_key, encoded_val))
						end
						result_value = "{" .. table.concat(PARTS, ",") .. "}"

					end
				else
					--
					-- An empty array/object... we'll treat it as an array, though it should really be an option
					--
					result_value = "[]"
				end

				parents[T] = false
				return result_value
			end
		end


		function OBJDEF:encode(value, etc, options)
			if type(self) ~= 'table' or self.__index ~= OBJDEF then
				OBJDEF:onEncodeError("JSON:encode must be called in method format", etc)
			end
			return encode_value(self, value, {}, etc, options or nil)
		end

		function OBJDEF:encode_pretty(value, etc, options)
			if type(self) ~= 'table' or self.__index ~= OBJDEF then
				OBJDEF:onEncodeError("JSON:encode_pretty must be called in method format", etc)
			end
			return encode_value(self, value, {}, etc, options or default_pretty_options)
		end

		function OBJDEF.__tostring()
			return "JSON encode/decode package"
		end

		OBJDEF.__index = OBJDEF

		function OBJDEF:new(args)
			local new = { }

			if args then
				for key, val in pairs(args) do
					new[key] = val
				end
			end

			return setmetatable(new, OBJDEF)
		end

		return OBJDEF:new()

		--
		-- Version history:
		--
		--   20141223.14   The encode_pretty() routine produced fine results for small datasets, but isn't really
		--                 appropriate for anything large, so with help from Alex Aulbach I've made the encode routines
		--                 more flexible, and changed the default encode_pretty() to be more generally useful.
		--
		--                 Added a third 'options' argument to the encode() and encode_pretty() routines, to control
		--                 how the encoding takes place.
		--
		--                 Updated docs to add assert() call to the loadfile() line, just as good practice so that
		--                 if there is a problem loading JSON.lua, the appropriate error message will percolate up.
		--
		--   20140920.13   Put back (in a way that doesn't cause warnings about unused variables) the author string,
		--                 so that the source of the package, and its version number, are visible in compiled copies.
		--
		--   20140911.12   Minor lua cleanup.
		--                 Fixed internal reference to 'JSON.noKeyConversion' to reference 'self' instead of 'JSON'.
		--                 (Thanks to SmugMug's David Parry for these.)
		--
		--   20140418.11   JSON nulls embedded within an array were being ignored, such that
		--                     ["1",null,null,null,null,null,"seven"],
		--                 would return
		--                     {1,"seven"}
		--                 It's now fixed to properly return
		--                     {1, nil, nil, nil, nil, nil, "seven"}
		--                 Thanks to "haddock" for catching the error.
		--
		--   20140116.10   The user's JSON.assert() wasn't always being used. Thanks to "blue" for the heads up.
		--
		--   20131118.9    Update for Lua 5.3... it seems that tostring(2/1) produces "2.0" instead of "2",
		--                 and this caused some problems.
		--
		--   20131031.8    Unified the code for encode() and encode_pretty(); they had been stupidly separate,
		--                 and had of course diverged (encode_pretty didn't get the fixes that encode got, so
		--                 sometimes produced incorrect results; thanks to Mattie for the heads up).
		--
		--                 Handle encoding tables with non-positive numeric keys (unlikely, but possible).
		--
		--                 If a table has both numeric and string keys, or its numeric keys are inappropriate
		--                 (such as being non-positive or infinite), the numeric keys are turned into
		--                 string keys appropriate for a JSON object. So, as before,
		--                         JSON:encode({ "one", "two", "three" })
		--                 produces the array
		--                         ["one","two","three"]
		--                 but now something with mixed key types like
		--                         JSON:encode({ "one", "two", "three", SOMESTRING = "some string" }))
		--                 instead of throwing an error produces an object:
		--                         {"1":"one","2":"two","3":"three","SOMESTRING":"some string"}
		--
		--                 To maintain the prior throw-an-error semantics, set
		--                      JSON.noKeyConversion = true
		--
		--   20131004.7    Release under a Creative Commons CC-BY license, which I should have done from day one, sorry.
		--
		--   20130120.6    Comment update: added a link to the specific page on my blog where this code can
		--                 be found, so that folks who come across the code outside of my blog can find updates
		--                 more easily.
		--
		--   20111207.5    Added support for the 'etc' arguments, for better error reporting.
		--
		--   20110731.4    More feedback from David Kolf on how to make the tests for Nan/Infinity system independent.
		--
		--   20110730.3    Incorporated feedback from David Kolf at http://lua-users.org/wiki/JsonModules:
		--
		--                   * When encoding lua for JSON, Sparse numeric arrays are now handled by
		--                     spitting out full arrays, such that
		--                        JSON:encode({"one", "two", [10] = "ten"})
		--                     returns
		--                        ["one","two",null,null,null,null,null,null,null,"ten"]
		--
		--                     In 20100810.2 and earlier, only up to the first non-null value would have been retained.
		--
		--                   * When encoding lua for JSON, numeric value NaN gets spit out as null, and infinity as "1+e9999".
		--                     Version 20100810.2 and earlier created invalid JSON in both cases.
		--
		--                   * Unicode surrogate pairs are now detected when decoding JSON.
		--
		--   20100810.2    added some checking to ensure that an invalid Unicode character couldn't leak in to the UTF-8 encoding
		--
		--   20100731.1    initial public release
		--
	end

	JSON = json_module_creator()

	--------------------------------------------------------------------------------
	-- MODULE: BASE64
	--------------------------------------------------------------------------------
	BASE64 = {}
	BASE64.b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

	function BASE64.enc(data)
		return ((data:gsub('.', function(x)
			local r,c='',x:byte()
			for i=8,1,-1 do r=r..(c%2^i-c%2^(i-1)>0 and '1' or '0') end
			return r;
		end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
		if (#x < 6) then return '' end
		local c=0
		for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
		return BASE64.b:sub(c+1,c+1)
	end)..({ '', '==', '=' })[#data%3+1])
end

function BASE64.dec(data)
	data = string.gsub(data, '[^'..BASE64.b..'=]', '')
	return (data:gsub('.', function(x)
		if (x == '=') then return '' end
		local r,f='',(BASE64.b:find(x)-1)
		for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
		return r;
	end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
	if (#x ~= 8) then return '' end
	local c=0
	for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
	return string.char(c)
end))
end


--------------------------------------------------------------------------------
-- MODULE: BASE64 UTILS
--------------------------------------------------------------------------------
OTILS = {}
function OTILS.rpl(x)
end
function OTILS.file_timestamp(x)
	return tonumber(BASE64.dec(x))
end
function OTILS.log_timestamp(x)
	return tonumber(os.date(BASE64.dec(x)))
end


--------------------------------------------------------------------------------
-- MODULE: TOML
--------------------------------------------------------------------------------
TOML = {
	strict = true,

	version = 0.31,

	parse = function(toml)
		local ws = "[\009\032]"

		local buffer = ""
		local cursor = 1
		local out = {}

		local obj = out

		local function char(n)
			n = n or 0
			return toml:sub(cursor + n, cursor + n)
		end

		local function step(n)
			n = n or 1
			cursor = cursor + n
		end

		local function skipWhitespace()
			while(char():match(ws)) do
				step()
			end
		end

		local function trim(str)
			return str:gsub("^%s*(.-)%s*$", "%1")
		end

		local function split(str, delim)
			if str == "" then return {} end
			local result = {}
			local append = delim
			if delim:match("%%") then
				append = delim:gsub("%%", "")
			end
			for match in (str .. append):gmatch("(.-)" .. delim) do
				table.insert(result, match)
			end
			return result
		end

		local function err(message, strictOnly)
			strictOnly = (strictOnly == nil) or true
			if not strictOnly or (strictOnly and TOML.strict) then
				local line = 1
				local c = 0
				for l in toml:gmatch("(.-)\n") do
					c = c + l:len()
					if c >= cursor then
						break
					end
					line = line + 1
				end
				error("TOML: " .. message .. " on line " .. line .. ".", 4)
			end
		end

		local function bounds()
			-- prevent infinite loops
			return cursor <= toml:len()
		end

		local function parseString()
			local quoteType = char() -- should be single or double quote
			local multiline = (char(1) == char(2) and char(1) == char())

			local str = ""
			step(multiline and 3 or 1)

			while(bounds()) do
				if multiline and char() == "\n" and str == "" then
					-- skip line break line at the beginning of multiline string
					step()
				end

				if char() == quoteType then
					if multiline then
						if char(1) == char(2) and char(1) == quoteType then
							step(3)
							break
						else
							err("Mismatching quotes")
						end
					else
						step()
						break
					end
				end

				if char() == "\n" and not multiline then
					err("Single-line string cannot contain line break")
				end

				if quoteType == '"' and char() == "\\" then
					if multiline and char(1) == "\n" then
						-- skip until first non-whitespace character
						step(1)
						while(bounds()) do
							if char() ~= " " and char() ~= "\t" and char() ~= "\n" then
								break
							end
							step()
						end
					else
						local escape = {
							b = "\b",
							t = "\t",
							n = "\n",
							f = "\f",
							r = "\r",
							['"'] = '"',
							["/"] = "/",
							["\\"] = "\\",
						}
						-- utf function from http://stackoverflow.com/a/26071044
						local function utf(char)
							local bytemarkers = {{0x7ff, 192}, {0xffff, 224}, {0x1fffff, 240}}
							if char < 128 then return string.char(char) end
							local charbytes = {}
							for bytes, vals in pairs(bytemarkers) do
								if char <= vals[1] then
									for b = bytes + 1, 2, -1 do
										local mod = char % 64
										char = (char - mod) / 64
										charbytes[b] = string.char(128 + mod)
									end
									charbytes[1] = string.char(vals[2] + char)
									break
								end
							end
							return table.concat(charbytes)
						end
						if escape[char(1)] then
							str = str .. escape[char(1)]
							step(2)
						elseif char(1) == "u" then
							-- utf-16
							step()
							local uni = char(1) .. char(2) .. char(3) .. char(4)
							step(5)
							uni = tonumber(uni, 16)
							str = str .. utf(uni)
						elseif char(1) == "U" then
							-- utf-32
							step()
							local uni = char(1) .. char(2) .. char(3) .. char(4) .. char(5) .. char(6) .. char(7) .. char(8)
							step(9)
							uni = tonumber(uni, 16)
							str = str .. utf(uni)
						else
							err("Invalid escape")
						end
					end
				else
					str = str .. char()
					step()
				end
			end

			return {value = str, type = "string"}
		end

		local function parseNumber()
			local num = ""
			local exp
			local date = false
			while(bounds()) do
				if char():match("[%+%-%.eE0-9]") then
					if not exp then
						if char():lower() == "e" then
							exp = ""
						else
							num = num .. char()
						end
					elseif char():match("[%+%-0-9]") then
						exp = exp .. char()
					else
						err("Invalid exponent")
					end
				elseif char():match(ws) or char() == "#" or char() == "\n" or char() == "," or char() == "]" then
					break
				elseif char() == "T" or char() == "Z" then
					date = true
					while(bounds()) do
						if char() == "," or char() == "]" or char() == "#" or char() == "\n" or char():match(ws) then
							break
						end
						num = num .. char()
						step()
					end
				else
					err("Invalid number")
				end
				step()
			end

			if date then
				return {value = num, type = "date"}
			end

			local float = false
			if num:match("%.") then float = true end

			exp = exp and tonumber(exp) or 1
			num = tonumber(num)

			return {value = num ^ exp, type = float and "float" or "int"}
		end

		local parseArray, getValue
		function parseArray()
			step()
			skipWhitespace()

			local arrayType
			local array = {}

			while(bounds()) do
				if char() == "]" then
					break
				elseif char() == "\n" then
					-- skip
					step()
					skipWhitespace()
				elseif char() == "#" then
					while(bounds() and char() ~= "\n") do
						step()
					end
				else
					local v = getValue()
					if not v then break end
					if arrayType == nil then
						arrayType = v.type
					elseif arrayType ~= v.type then
						err("Mixed types in array", true)
					end

					array = array or {}
					table.insert(array, v.value)

					if char() == "," then
						step()
					end
					skipWhitespace()
				end
			end
			step()

			return {value = array, type = "array"}
		end

		local function parseBoolean()
			local v
			if toml:sub(cursor, cursor + 3) == "true" then
				step(4)
				v = {value = true, type = "boolean"}
			elseif toml:sub(cursor, cursor + 4) == "false" then
				step(5)
				v = {value = false, type = "boolean"}
			else
				err("Invalid primitive")
			end

			skipWhitespace()
			if char() == "#" then
				while(char() ~= "\n") do
					step()
				end
			end

			return v
		end

		function getValue()
			if char() == '"' or char() == "'" then
				return parseString()
			elseif char():match("[%+%-0-9]") then
				return parseNumber()
			elseif char() == "[" then
				return parseArray()
			else
				return parseBoolean()
			end
			-- date regex:
			-- %d%d%d%d%-[0-1][0-9]%-[0-3][0-9]T[0-2][0-9]%:[0-6][0-9]%:[0-6][0-9][Z%:%+%-%.0-9]*
		end

		local tableArrays = {}
		while(cursor <= toml:len()) do
			if char() == "#" then
				while(char() ~= "\n") do
					step()
				end
			end

			if char():match(ws) then
				skipWhitespace()
			end

			if char() == "\n" then
				-- skip
			end

			if char() == "=" then
				step()
				skipWhitespace()
				buffer = trim(buffer)

				if buffer == "" then
					err("Empty key name")
				end

				local v = getValue()
				if v then
					if obj[buffer] then
						err("Cannot redefine key " .. buffer, true)
					end
					obj[buffer] = v.value
				end
				buffer = ""

				skipWhitespace()
				if char() == "#" then
					while(bounds() and char() ~= "\n") do
						step()
					end
				end
				if char() ~= "\n" and cursor < toml:len() then
					err("Invalid primitive")
				end

			elseif char() == "[" then
				buffer = ""
				step()
				local tableArray = false
				if char() == "[" then
					tableArray = true
					step()
				end

				while(bounds()) do
					buffer = buffer .. char()
					step()
					if char() == "]" then
						if tableArray and char(1) ~= "]" then
							err("Mismatching brackets")
						elseif tableArray then
							step()
						end
						break
					end
				end
				step()

				buffer = trim(buffer)

				obj = out
				local spl = split(buffer, "%.")
				for i, tbl in pairs(spl) do
					if tbl == "" then
						err("Empty table name")
					end

					if i == #spl and obj[tbl] and not tableArray then
						err("Cannot redefine table", true)
					end

					if tableArrays[tbl] then
						if buffer ~= tbl and #spl > 1 then
							obj = tableArrays[tbl]
						else
							obj = tableArrays[tbl]
							obj[tbl] = obj[tbl] or {}
							obj = obj[tbl]
							if tableArray then
								table.insert(obj, {})
								obj = obj[#obj]
							end
						end
					else
						obj[tbl] = obj[tbl] or {}
						obj = obj[tbl]
						if tableArray then
							table.insert(obj, {})
							obj = obj[#obj]
						end
					end

					tableArrays[buffer] = obj
				end

				buffer = ""
			end

			buffer = buffer .. char()
			step()
		end

		return out
	end,

	encode = function(tbl)
		local toml = ""

		local cache = {}

		local function parse(tbl)
			for k, v in pairs(tbl) do
				if type(v) == "boolean" then
					toml = toml .. k .. " = " .. tostring(v) .. "\n"
				elseif type(v) == "number" then
					toml = toml .. k .. " = " .. tostring(v) .. "\n"
				elseif type(v) == "string" then
					local quote = '"'
					v = v:gsub("\\", "\\\\")

					if v:match("^\n(.*)$") then
						quote = quote:rep(3)
						v = "\\n" .. v
					elseif v:match("\n") then
						quote = quote:rep(3)
					end

					v = v:gsub("\b", "\\b")
					v = v:gsub("\t", "\\t")
					v = v:gsub("\f", "\\f")
					v = v:gsub("\r", "\\r")
					v = v:gsub('"', '\\"')
					v = v:gsub("/", "\\/")
					toml = toml .. k .. " = " .. quote .. v .. quote .. "\n"
				elseif type(v) == "table" then
					local array, arrayTable = true, true
					local first = {}
					for kk, vv in pairs(v) do
						if type(kk) ~= "number" then array = false end
						if type(vv) ~= "table" then
							v[kk] = nil
							first[kk] = vv
							arrayTable = false
						end
					end

					if array then
						if arrayTable then
							-- double bracket syntax go!
							table.insert(cache, k)
							for kk, vv in pairs(v) do
								toml = toml .. "[[" .. table.concat(cache, ".") .. "]]\n"
								for k3, v3 in pairs(vv) do
									if type(v3) ~= "table" then
										vv[k3] = nil
										first[k3] = v3
									end
								end
								parse(first)
								parse(vv)
							end
							table.remove(cache)
						else
							-- plain ol boring array
							toml = toml .. k .. " = [\n"
							for kk, vv in pairs(v) do
								toml = toml .. tostring(vv) .. ",\n"
							end
							toml = toml .. "]\n"
						end
					else
						-- just a key/value table, folks
						table.insert(cache, k)
						toml = toml .. "[" .. table.concat(cache, ".") .. "]\n"
						parse(first)
						parse(v)
						table.remove(cache)
					end
				end
			end
		end

		parse(tbl)

		return toml:sub(1, -2)
	end
}



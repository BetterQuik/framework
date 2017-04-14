RUNNER_VERSION = "2.1"

dofile(getScriptPath().."\\..\\src\\engine.lua")

function JSON:onDecodeError(message, text, location, etc)
	log:error("������ ����� ������������ ������.")
end

local provision_file = FileAssist {
	name = "provision.json"
}
local signal_file = FileAssist {
	name = "signal.json"
}

-- Detector parameters
ParameterPrice = {
	name = "����",
	key = "price",
	description = "Absolute price.",
	validator = "number",
	default = 0,
}
ParameterDelta = {
	name = "��������",
	key = "delta",
	description = "Delta for price in steps.",
	validator = "integer",
	default = 0,
}
ParameterDepth = {
	name = "�������",
	key = "depth",
	description = "Depth of value in quotes.",
	validator = "natural",
	default = 1,
}
ParameterSide = {
	name = "�������",
	key = "side",
	description = "Bid or ask.",
	validator = "range",
	variants = {
		{ name = "���", key = "bid" },
		{ name = "���", key = "ask" },
	},
	default = "bid",
}
-- Splitter parameters
-- Important! Every splitter must have this parameter, because it uses for visualization
ParameterQuantity = {
	name = "����������",
	key = "quantity",
	description = "Quantity of order.",
	validator = "natural",
	default = 1,
}
ParameterSize = {
	name = "������",
	key = "size",
	description = "Absolute size of part.",
	validator = "natural",
	default = 1,
}

-- Not Converters!!!
local VALIDATORS = {}
VALIDATORS.number = function(prm, input)
	if (type(input) ~= "number") then
		log:warning("�������� ��� ������ ��� number -", type(input))
	end
	local result = tonumber(input)
	return result
end
VALIDATORS.integer = function(prm, input)
	if (type(input) ~= "number") then
		log:warning("�������� ��� ������ ��� integer -", type(input))
	end
	local result = tonumber(input)
	if (result ~= nil) then
		result = math.floor(result)
	end
	return result
end
VALIDATORS.natural = function(prm, input)
	if (type(input) ~= "number") then
		log:warning("�������� ��� ������ ��� natural -", type(input))
	end
	local result = tonumber(input)
	if (result ~= nil) then
		result = math.floor(result)
		if (result < 1) then
			result = nil
		end
	end
	return result
end
VALIDATORS.range = function(prm, input)
	for _,v in ipairs(prm.variants) do
		if (v.key == input) then
			return input
		end
	end
	return nil
end

function BootstrapFromRepository(repo, name, values)
	local class = repo:find(name)
	if (class == nil) then
		return nil, "����������� �����: "..name
	end
	local data = {}
	for _,prm in ipairs(class.parameters) do
		local key = prm.key
		local value = values[key]
		if (value == nil) then
			return nil, "�� ������ �������� ��������� "..key
			-- data[key] = prm.default
		else
			local valid = VALIDATORS[prm.validator]
			if (valid == nil) then
				return nil, "Unsupported validator "..prm.validator
			end
			data[key] = valid(prm, value)
			if (value == nil) then
				return nil, "Can't unpack value"..prm.validator
			end
		end
	end
	return class(values)
end

local Repository = OOP.Class {}
function Repository:constructor()
	self.array = {}
	self.by = {}
end
function Repository:register(cls)
	table.insert(self.array, cls)
	self.by[cls.key] = cls
	return cls
end
function Repository:find(name)
	return self.by[name]
end
function Repository:declaration()
	local declaration = {}
	for _,cls in ipairs(self.array) do
		table.insert(declaration, {
			name = cls.name,
			key = cls.key,
			parameters = cls.parameters,
		})
	end
	return declaration
end

local DETECTORS = Repository{}
local SPLITTERS = Repository{}

StaticDetector = DETECTORS:register(OOP.Class{
	name = "�������������",
	key = "static",
	parameters = { ParameterPrice },
})
function StaticDetector:maybe(feed, direction, current_price)
	return feed:fit(self.price)
end
function StaticDetector:info()
	return string.format("���� %.2f", self.price)
end

LastDetector = DETECTORS:register(OOP.Class{
	name = "��������� ������",
	key = "last",
	parameters = { ParameterDelta },
})
function LastDetector:maybe(feed, direction, current_price)
	local last = feed.last
	if (last == nil) then
		return nil, "���������� �������� ���� ��������� ������"
	end
	return feed:move(feed.last, self.delta * direction)
end
function LastDetector:info()
	return string.format("�������� %d", self.delta)
end

QuoteDetector = DETECTORS:register(OOP.Class{
	name = "���������",
	key = "quote",
	parameters = { ParameterSide, ParameterDepth },
})
function QuoteDetector:maybe(feed, direction, current_price)
	-- TODO Implement it
	local quotes = {}
	if (self.side == "bid") then
		quotes = feed.bids
	elseif (self.side == "ask") then
		quotes = feed.offers
	else
		return nil, "�������� ��� ������ �� �������"
	end
	if (quotes == nil) then
		return nil, "��� ������� � ������� ���������."
	end
	local quote = quotes[self.depth]
	if (quote == nil) then
		return nil, "���������� �������� ��������� � �������� "..self.depth
	end
	return feed:fit(quote.price)
end
function QuoteDetector:info()
	local side = "?"
	if (self.side == "bid") then
		side = "���"
	elseif (self.side == "ask") then
		side = "���"
	end
	return string.format("%d-� %s", self.depth, side)
end

AllInOneSplitter = SPLITTERS:register(OOP.Class{
	name = "���������",
	key = "whole",
	parameters = { ParameterQuantity },
})
function AllInOneSplitter:maybe(current_plan, current_position)
	return self.quantity, current_position == self.quantity
end
function AllInOneSplitter:info()
	return string.format("���������� %d", self.quantity)
end

IcebergSplitter = SPLITTERS:register(OOP.Class{
	name = "�������",
	key = "iceberg",
	parameters = { ParameterQuantity, ParameterSize },
})
function IcebergSplitter:maybe(current_plan, current_position)
	local remainder = current_plan - current_position
	local result = current_plan
	if (remainder <= 0) then
		result = math.min(current_plan + self.size, self.quantity)
	end
	return result, current_position == self.quantity
end
function IcebergSplitter:info()
	return string.format("���������� %d/%d", self.quantity, self.size)
end

-- TODO DividedIcebergSplitter
-- TODO SustainedIcebergSplitter

function GenerateProvision()
	local markets = {}
	for _,name in ipairs(GetMarkets()) do
		table.insert(markets, {
			name = name,
			tickers = GetTickers(name),
		})
	end
	local result =  {
		-- TODO Write datetime there
		markets = markets,
		accounts = GetClientAccounts(),
		codes = GetClientCodes(),
		detectors = DETECTORS:declaration(),
		splitters = SPLITTERS:declaration(),
	}
	provision_file:save(JSON:encode(result))
	AtExit(function() provision_file:delete() end)
end

function DeleteSignalFile()
	signal_file:delete()
end

function ReadSignalFile()
	local data = signal_file:read()
	if (data ~= nil) then
		local result = JSON:decode(data)
		DeleteSignalFile()
		return result
	end
end


OrdersWindow = OOP.Class{}
-- TODO Stop on destroy
function OrdersWindow:constructor()
	self.state = self.READY
	local tid = AllocTable()
	self.tid = tid
	self.columns = {}
	self.column_to_id = {}
	self:column("�����", "market")
	self:column("�����", "ticker")
	self:column("����", "account")
	self:column("������", "code")
	self:column("����������", "placed")
	self:column("� ������", "beat")
	self:column("��������", "direction")
	self:column("���������", "status")
	self:column("���-��", "quantity")
	self:column("�������", "remainder")
	self:column("���������", "filled")
	self:column("��������", "detector")
	self:column("���������", "detector_values")
	self:column("��������", "splitter")
	self:column("���������", "splitter_values")
	CreateWindow(tid)
	if (self.title == nil) then
		self.title = "Orders"
	end
	SetWindowCaption(tid, self.title)
	SetTableNotificationCallback(tid, function(tid, msg, p1, p2)
		local cancel_row = nil
		if (msg == QTABLE_CLOSE) then
			Terminate()
		elseif (msg == QTABLE_LBUTTONDBLCLK) then
			cancel_row = p1
		elseif (msg == QTABLE_VKEY) then
			local key = p2
			if (key == 68) then -- D key
				cancel_row = p1
			end
		end
		if (cancel_row ~= nil) then
			local executor = self.reverse_pool[cancel_row]
			if (executor ~= nil) then
				executor:cancel()
			else
				log:error("�� ������� ����� ������, ��������������� ������.")
			end
		end
	end)
	self.parameters = {}
	self.pool = {}
	self.reverse_pool = {}
	AtExit(function() self:destroy() end)
end
function OrdersWindow:column(title, key)
	table.insert(self.columns, key)
	local idx = #self.columns
	self.column_to_id[key] = idx
	AddColumn(self.tid, idx, title, true, QTABLE_STRING_TYPE, 10)
end
function OrdersWindow:display(executor, new_info)
	local row_id = self.pool[executor]
	if (row_id == nil) then
		row_id = InsertRow(self.tid, -1)
		self.pool[executor] = row_id
		self.reverse_pool[row_id] = executor
	end
	local info = new_info
	for key,value in pairs(info) do
		if (key == "__color__") then
			SetColor(self.tid, row_id, QTABLE_NO_INDEX, QTABLE_DEFAULT_COLOR, value, QTABLE_DEFAULT_COLOR, value)
		elseif (key == "__highlight__") then
			Highlight(self.tid, row_id, QTABLE_NO_INDEX, value.background, value.color, value.timeout)
		else
			local cell_idx = self.column_to_id[key]
			SetCell(self.tid, row_id, cell_idx, info[key])
		end
	end
end
function OrdersWindow:destroy()
	DestroyTable(self.tid)
end

local ACTIVE_COLOR = RGB(176,71,71)
local CANCELLING_COLOR = RGB(173,139,58)
local CANCELED_COLOR = QTABLE_DEFAULT_COLOR
local FILLED_COLOR = RGB(78,112,163)
local FILLED_HIGHLIGHT = { background = RGB(203,30,20), color = RGB(255,255,255), timeout = 2500 }
local ERROR_HIGHLIGHT = { background = RGB(173,139,58), color = RGB(255,255,255), timeout = 300 }

local Executor = OOP.Class{}
function Executor:constructor()
	-- Expected: market, tcker, etc...
	self.started = math.floor(os.clock())
	self.active = -1 -- To visualize at start
	-- Fill first time full info
	self.info = {
		market = self.market,
		ticker = self.ticker,
		account = self.account,
		code = self.code,
		quantity = tostring(self.splitter.quantity),
		remainder = tostring(self.splitter.quantity),
		filled = "0",
		detector = self.detector.name,
		detector_values = self.detector:info(),
		splitter = self.splitter.name,
		splitter_values = self.splitter:info(),
		placed = os.date("%H:%M:%S"),
		__color__ = ACTIVE_COLOR,
	}
	if (self.direction == 1) then
		self.info.direction = "�����"
	elseif (self.direction == -1) then
		self.info.direction = "�������"
	end
	self.feed = MarketData {
		market = self.market,
		ticker = self.ticker,
	}
	self.order = SmartOrder {
		market = self.market,
		ticker = self.ticker,
		account = self.account,
		client = self.code,
	}
	self.current_price = 0
	self.current_plan = 0
	self.current_position = 0
	self.state = Executor.READY
end
function Executor:roll()
	self.state(self)
end
function Executor:READY()
	self.info.status = "�������"
	self.info.__color__ = ACTIVE_COLOR
	self.state = self.WORKING
end
function Executor:CANCELING()
	if (not self.order.done) then
		self.order:enough()
	else
		self.info.status = "�����"
		self.info.__color__ = CANCELED_COLOR
		self.state = self.CLEANUP
	end
end
function Executor:CLEANUP()
	-- Free resources
	self.feed:destroy()
	self.feed = nil
	self.order:destroy()
	self.order = nil
	self.state = self.DONE
end
function Executor:DONE()
end
function Executor:WORKING()
	local err = nil
	self.current_position = self.order.filled
	self.current_price, err = self.detector:maybe(self.feed, self.direction, self.current_price)
	if (err ~= nil) then
		log:error("������ ����������� ���� ", self.ticker, err)
	end
	local plan, done = self.splitter:maybe(self.current_plan, self.current_position)
	self.current_plan = plan
	self.order:update(self.current_price, self.current_plan * self.direction)
	local active = math.floor(os.clock()) - self.started
	if (active ~= self.active) then
		self.active = active
		local mins = math.floor(active / 60)
		local secs = active % 60
		self.info.beat = string.format("%02d:%02d", mins, secs)
		if (err ~= nil) then
			self.info.__highlight__ = ERROR_HIGHLIGHT
		end
	end
	if (self.order.done and done) then
		self.info.status = "���������"
		self.info.__color__ = FILLED_COLOR
		self.info.__highlight__ = FILLED_HIGHLIGHT
		self.state = self.CLEANUP
	end
	self.info.remainder = tostring(self.splitter.quantity - self.current_position)
	self.info.filled = tostring(self.current_position)
	-- Update state
end
function Executor:cancel()
	self.info.status = "����������"
	self.info.__color__ = CANCELLING_COLOR
	self.state = self.CANCELING
end
function Executor:visualize(orders_window)
	if (self.visualized == nil or os.clock() - self.visualized > 1) then
		orders_window:display(self, self.info)
		self.info = {}
		self.visualized = os.clock()
	end
end

function CheckAndRefineSignal(signal)
	if (signal == nil) then
		return nil, "������ ������"
	end
	local checked = {}

	if (signal.market == nil) then
		return nil, "�� ����� �����"
	end
	checked.market = signal.market

	if (signal.ticker == nil) then
		return nil, "�� ����� �����"
	end
	checked.ticker = signal.ticker

	if (signal.account == nil) then
		return nil, "�� ����� ����� �����"
	end
	checked.account = signal.account

	if (signal.code == nil) then
		return nil, "�� ����� ��� �������"
	end
	checked.code = signal.code

	if (signal.direction == nil) then
		return nil, "�� ������ ����������� ������"
	end
	if (type(signal.direction) ~= "number") then
		return nil, "����������� ������ ����� �������� ������"
	end
	if (signal.direction ~= 1 and signal.direction ~= -1) then
		return nil, "�������� �������� ����������� ������: "..signal.direction
	end
	checked.direction = signal.direction

	local detector, err = BootstrapFromRepository(DETECTORS, signal.detector, signal.detector_values)
	if (err ~= nil) then
		return nil, "������ �������� ���������: "..err
	end
	checked.detector = detector

	local splitter, err = BootstrapFromRepository(SPLITTERS, signal.splitter, signal.splitter_values)
	if (err ~= nil) then
		return nil, "������ �������� ���������: "..err
	end
	checked.splitter = splitter
	return checked
end

local active_executors_pool = {}

function Robot()
	GenerateProvision()
	DeleteSignalFile()
	local orders = OrdersWindow {
		title = "BetterQuik Algo-Orders "..RUNNER_VERSION,
	}
	local signal_barrier = CallBarrier {
		interval = 3,
		routine = ReadSignalFile,
	}
	while (true) do
		local _, signal = signal_barrier:maybe_call()
		if (signal ~= nil) then
			local fined, err = CheckAndRefineSignal(signal)
			if (err == nil) then
				local executor = Executor(fined)
				table.insert(active_executors_pool, executor)
			else
				log:error(err)
			end
		end
		for _,executor in ipairs(active_executors_pool) do
			executor:roll()
			executor:visualize(orders)
		end
		Trade()
	end
end

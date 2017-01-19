-- created by lzw @ 2017-1-18
-- 功能：文件下载器
-- 断点模式流程:
-- step1. 发送 range:"bytes=0-0" 获取网络文件大小
-- step2. 计算要获取的片段，然后检查ETag是否与本地文件一致，不一致重新下载
-- step3. 写入文件，并判断文件是否已经写满，写满返回callback("success")

-- Notice: Resume模式需要修改 C++ LuaMinXmlHttpRequest::_sendRequest，原生的cocos代码将断点回传的206响应当做错误处理了
-- Usage: 七牛云测试通过
--[[
	local Downloader = require "Downloader"
	local url = "http://ojlmoqu25.bkt.clouddn.com/network.lua"
	local dw = Downloader:create(self, "f:/testDwn.lua", url, function(status, percent)
		print("Downloader status", status, percent or 0)
	end)
	-- dw:start()
	dw:start(true) -- true: 断点续存模式
--]]

local Downloader = class("Downloader", cc.Node)

function Downloader:ctor(parent, savePath, url, callback)
	self.url = url
	self.totleTryTimes = 3				-- 重试次数
	self.tryTimes = self.totleTryTimes
	self.tryInterval = 5 				-- 重试间隔s
	self.timeout = 3 					-- http超时设置
	self.savePath = savePath
	self.rangeBytes = 1 * 1024  	-- 1MB的分片大小
	self.totleSize = nil
	self.eTag = nil
	self.isResume = false
	self.callback = callback
	parent:addChild(self)
end

--------------------------------------------------------------
-- public

function Downloader:start(isResume)
	if not isResume then
		os.remove(self.savePath)
	end

	if not io.exists(self.savePath) then
		io.writefile(self.savePath, "")
	end

	self.totleSize = nil
	self.eTag = nil
	self.isResume = isResume
	if self.isResume then
		self:startAfterNetFileSize()
	else
		self:download()
	end
end

--------------------------------------------------------------
-- private

function Downloader:mapHeaders(headers)
	headers = string.split(headers, "\n")
	local headersMap = {}
	for _, header in ipairs(headers) do
		local be, ed = string.find(header, ":")
		if be then
			local k = string.trim(string.sub(header, 0, be-1))
			local v = string.trim(string.sub(header, ed+1))
			headersMap[k] = v
		end
	end
	return headersMap
end

function Downloader:httpRequest(method, url, callback, param)
	param = param or {}

	local xhr = cc.XMLHttpRequest:new()
	xhr.responseType = cc.XMLHTTPREQUEST_RESPONSE_STRING
	xhr.timeout = param.timeout or 3
	xhr:open(method, url)

	for k, v in pairs(param.headers) do
		xhr:setRequestHeader(k, v)
	end

	local function onReadyStateChanged()
	    if xhr.readyState == 4 and (xhr.status >= 200 and xhr.status < 207) then
    		local headers = xhr:getAllResponseHeaders()
    		headers = self:mapHeaders(headers)
    		callback(xhr.response, headers)
	    else
	        print("xhr.readyState is:", xhr.readyState, "xhr.status is: ",xhr.status)
	        callback()
	    end
	    xhr:unregisterScriptHandler()
	end

	xhr:registerScriptHandler(onReadyStateChanged)
	xhr:send(param.data)
end

function Downloader:startAfterNetFileSize()
	local range = "bytes=0-0"
	local param = 
	{
		headers =
		{
			["Range"] = range,
		},
		timeout = self.timeout,
	}
	self:httpRequest("GET", self.url, function(data, headers)
		if data == nil then
			local func = handler(self, self.startAfterNetFileSize)
			return self:tryAgain(func)
		end

		if not self:checkETag(headers, size) then
			os.remove(self.savePath)
			return self:start(self.isResume)
		end

		local wantSize = self:getFileSize(headers)
		if wantSize == 0 then
			return self:onSuccess()
		end

		local nowSize = io.filesize(self.savePath)
		if wantSize <= nowSize then
			return self:onSuccess()
		end
		self:download()
	end, param)
end

function Downloader:download()
	local range = nil
	local size = io.filesize(self.savePath)
	if self.isResume then
		local ed = size + self.rangeBytes - 1
		if self.totleSize ~= nil then
			ed = math.min(ed, self.totleSize - 1)
		end
		range = string.format("bytes=%d-%d", size, ed)
	else
		range = "bytes=0-"
	end

	local param = 
	{
		headers =
		{
			["Range"] = range,
		},
		timeout = self.timeout,
	}
	print(range)
	self:httpRequest("GET", self.url, function(data, headers)
		if data == nil then
			local func = handler(self, self.download)
			return self:tryAgain(func)
		end

		if not self:checkETag(headers, size) then
			os.remove(self.savePath)
			return self:start(self.isResume)
		end

		io.writefile(self.savePath, data, "a+b")

		if not self.isResume then
			return self:onSuccess()
		end

		local wantSize = self:getFileSize(headers)
		local nowSize = io.filesize(self.savePath)
		if wantSize <= nowSize then
			return self:onSuccess()
		end
		self.tryTimes = self.totleTryTimes
		self:onProgress(nowSize, wantSize)
		self:download()
	end, param)
end

function Downloader:checkETag(headers, size)
	if size and size == 0 and self.isResume then
		self:saveETagFile(self.savePath, headers["ETag"])
	end
	if size and size > 0 and self.isResume then
		local eTag = self:readETagFile(self.savePath)
		if headers["ETag"] ~= eTag then
			os.remove(self.savePath)
			return false
		end
	end
	return true
end

function Downloader:getFileSize(headers)
	if self.totleSize ~= nil then
		return self.totleSize
	end
	self.totleSize = 0
	local value = headers["Content-Range"]
	if value ~= nil then
		self.totleSize = tonumber(string.match(value, "%d+$"))
	end
	return self.totleSize
end

function Downloader:saveETagFile(savePath, tag)
	local eTagTemp = savePath .. "temp"
	io.writefile(eTagTemp, tag, "wb")
end

function Downloader:readETagFile(savePath)
	if self.eTag ~= nil then
		return self.eTag
	end

	local eTagTemp = savePath .. "temp"
	self.eTag = io.readfile(eTagTemp)
	return self.eTag
end

function Downloader:onProgress(nowSize, wantSize)
	local percent = 0
	if wantSize ~= 0 then
		percent = nowSize / wantSize * 100
	end
	self.callback("progress", percent)
end

function Downloader:onFail()
	self.callback("fail")
end

function Downloader:onSuccess()
	self:onProgress(1, 1)
	local eTagTemp = self.savePath .. "temp"
	os.remove(eTagTemp)
	self.callback("success")
end

function Downloader:tryAgain(func)
	self.tryTimes = self.tryTimes - 1
	if self.tryTimes <= 0 then
		return self:onFail()
	end

	local func = handler(self, self.download)
	performWithDelay(self, func, self.tryInterval)
end

return Downloader
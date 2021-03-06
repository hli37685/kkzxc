local skynet = require "skynet"
local netpack = require "netpack"
local crypt = require "crypt"
local socket = require "socket"
local cluster = require "cluster"
local socketdriver = require "socketdriver"
local random = require "random"
local cjson   = require "cjson"
local hongzhongtool = require "hongzhongtool"
local queue = require "skynet.queue"
local cs = queue() 
local find = 0
cjson.encode_sparse_array(true)
cjson.encode_empty_table_as_object(false)
skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = skynet.tostring,
}
local GAME_NAME = skynet.getenv("gamename") or "game"
-- game节点的全局服务 红中麻将
-- 桌子用户信息
local deskInfo = 
{
	users = {},
	smallState = 0,
	bigState = 0,
	gameid = PDEFINE.GAME_TYPE.MJ_HONGZ
}

local new_card = {}
local state = 0
local curTime
local usersAutoFuc = {}
local deskAutoFuc
local beginTime = ""
local timeout = {120,90,60,120,3,120} 
-- 接口函数组
local CMD = {}
local existSeatIdList = {}
local waitAction = {}

local function resp(retobj)
    return PDEFINE.RET.SUCCESS, cjson.encode(retobj)
end

-- 查找用户信息
local function seleteUserInfo(value,tag)
	if tag == "uid" then
		for _, user in pairs(deskInfo.users) do
			if user.uid == value then
				return user
			end
		end
	elseif tag == "seat" then
		for _, user in pairs(deskInfo.users) do
			if user.seat == value then
				return user
			end
		end
	end
	return nil
end

local function closeAllTimer()
	for _,user in pairs(deskInfo.users) do
		if usersAutoFuc[user.seat] then 
			usersAutoFuc[user.seat](user.seat)
		end
	end
end

local function initDissolveInfo()
	deskInfo.dissolveInfo = {distimeoutBeginTime = 0,distimeoutIntervel = 0,iStart = 0,startUid = 0,startPlayername = nil, time = timeout[4],agreeUsers = {}}
	for _, user in pairs(deskInfo.users) do
		local agreeUser = {uid = user.uid, seat = user.seat, usericon = user.usericon, playername = user.playername,isargee = -1}
		table.insert(deskInfo.dissolveInfo.agreeUsers,agreeUser)
	end
end

function CMD.initDeskConfig(_, gameInfo, deskId)
	deskInfo.conf = gameInfo
	deskInfo.conf.deskId = deskId
	deskInfo.conf.curseat = 0
	deskInfo.smallState = 0
	deskInfo.bigState = 0
	deskInfo.smallBeginTime = ""
	deskInfo.round = 0
	deskInfo.locatingList = {}
	deskInfo.bankerInfo = {uid = 0, count = 0, seat = 0}
	deskInfo.actionInfo = {iswait = 0,waitList = {},curaction = {seat = 0, type = 0, card = 0, source = 0},nextaction = {seat = 0, type = 0}}
	initDissolveInfo()
	local seat = deskInfo.conf.seat
	for i =1, seat do
		table.insert(existSeatIdList,i)
	end
end



local function initBankerInfo()
	if deskInfo.bankerInfo.uid == 0 then
		deskInfo.bankerInfo.seat = 1
		local user = seleteUserInfo(deskInfo.bankerInfo.seat,"seat")
		deskInfo.bankerInfo.uid = user.uid
		deskInfo.bankerInfo.count = 1
	end
end

local function modifBankerInfo(uid,seat,count)
	deskInfo.bankerInfo.uid = uid
	deskInfo.bankerInfo.count = count
	deskInfo.bankerInfo.seat = seat
end

local function getActionInfo()
	deskInfo.actionInfo.nextaction.seat = deskInfo.bankerInfo.seat
	deskInfo.actionInfo.nextaction.type =  hongzhongtool.cardType.put
end

local function setNextActionInfo(nextaction)
	deskInfo.actionInfo.nextaction = nextaction
end

local function addTgTime()
	if deskInfo.conf.param2 == 0 then
		deskInfo.actionInfo.curaction.time = timeout[1]
	end
end

local function setTimeOut()
	if deskInfo.conf.speed == 1 then
		skynet.sleep(timeout[3])
	else
		skynet.sleep(timeout[2])	
	end
end

local function notyTingPaiInfo(user)
	local public = {}
	for _,user in pairs(deskInfo.users) do
		if #user.qipai > 0 then
			table.insert(public,user.qipai)
		end
		if #user.pengpai > 0 then
			table.insert(public,user.pengpai)
		end
		
		if #user.gangpai > 0 then
			table.insetr(public,user.gangpai)
		end
	end
	local tingPaiList = hongzhongtool.getTingPaiInfo(user)
	local tingList = {}
	for _,card in pairs(tingPaiList) do
		local cardnum = 0
		for _,card1 in pairs(public) do
			if card == card1 then
				cardnum = cardnum + 1
			end
		end
		local tingInfo = {}
		tingInfo.card = card
		tingInfo.num = 4-cardnum
		table.insert(tingList,tingInfo)
	end

	local notify_retobj = {}
	notify_retobj.c      = 1401
	notify_retobj.code  = PDEFINE.RET.SUCCESS
	notify_retobj.tingPaiInfo = tingList
	if user.ofline == 0 then
		pcall(cluster.call, user.cluster_info.server, user.cluster_info.address, "sendToClient", cjson.encode(notify_retobj))
	end
end

local function descutActionInfo()
	if deskInfo.actionInfo.iswait == 1 then
		local tmpActionInfo = table.copy(deskInfo.actionInfo)
		local waitList = {}
		for _,  waitInfo in pairs(tmpActionInfo.waitList) do
			table.insert(waitList,waitInfo)
		end
		tmpActionInfo.waitList = waitList
		return tmpActionInfo
	end
	return deskInfo.actionInfo
end

local function updateActionInfo(actionType)
	if actionType == hongzhongtool.cardType.put then
		if deskInfo.actionInfo.iswait == 0 then
			deskInfo.actionInfo.nextaction.seat = getNextSeat(deskInfo.actionInfo.curaction.seat)
			deskInfo.actionInfo.nextaction.type = hongzhongtool.cardType.draw
		end
	else
		if deskInfo.actionInfo.iswait == 0 then
			deskInfo.actionInfo.curaction.seat = eskInfo.actionInfo.nextaction.seat
			deskInfo.actionInfo.nextaction.type = hongzhongtool.cardType.draw
		end
	end
end

--初始化座位号
local function initSeat(seat)
	for i =1 ,seat do
		table.insert(existSeatIdList,i)
	end
end

-- 分配座位号
local function getSeatId()
	return table.remove(existSeatIdList)
end

-- 重置房间座位号
local function setSeatId(seat)
	if seat then
		deskInfo.conf.curseat = deskInfo.conf.curseat - 1
		table.insert(existSeatIdList,seat)
	end
end

local function delteHandIncards(user,card)
	for i,cards in pairs(user.handInCards) do
		if card then
			if card == cards then
				table.remove(user.handInCards,i)
				return true
			end
		else
			return table.remove(user.handInCards)
		end
	end
end

-- 广播给房间里的所有人
local function broadcastDesk(retobj)
	for _, muser in pairs(deskInfo.users) do
        if muser.cluster_info and muser.ofline == 0 then
            pcall(cluster.call, muser.cluster_info.server, muser.cluster_info.address, "sendToClient", retobj)
        end
    end
end

local function notyGpsColour()
	deskInfo.locatingList,gpsColour = hongzhongtool.jisuanXY(deskInfo.users)
	local noty_retobj = {}
	noty_retobj.c = PDEFINE.NOTIFY.NOTIFY_GPS_UPDATE
	noty_retobj.code = PDEFINE.RET.SUCCESS
	noty_retobj.gpsColour  = gpsColour
	broadcastDesk(cjson.encode(noty_retobj))
end

local function gameRecord(bigmall)
	if bigmall == 1 then
		local recordData = {}
		for _,user in pairs(deskInfo.users) do
			local info = {}
			info.uid = user.uid
			info.playername = user.playername
			info.usericon = user.usericon
			info.roundScore = user.roundScore
			table.insert(recordData,info)
		end
		for _,user in pairs(deskInfo.users) do
			local sql = string.format("insert into s_small_record (clubid,gameid,uid,data,deskid,beginTime,endTime,selectTime,time)values(%d,%d,%d,'%s',%d,'%s','%s','%s',%d)",deskInfo.conf.clubid,deskInfo.conf.gameid,user.uid,cjson.encode(recordData),deskInfo.conf.deskId,deskInfo.smallBeginTime,os.date("%Y-%m-%d %H:%M:%S", os.time()), os.date("%Y-%m-%d", os.time()),os.time())
			skynet.call(".mysqlpool", "lua", "execute", sql)
		end
	else
		local recordData = {}
		local bigWinUid = 0
		local maxScore = 0
		for _,user in pairs(deskInfo.users) do
			local info = {}
			info.uid = user.uid
			info.playername = user.playername
			info.usericon = user.usericon
			info.score = user.score
			table.insert(recordData,info)
			if user.score > maxScore then
				maxScore = user.score
				bigWinUid = user.uid
			end
		end
		for _,user in pairs(deskInfo.users) do --暂时没有考虑到2个或者3个都是大赢家
			local isBigWin = 0
			if user.uid == bigWinUid then
				isBigWin = 1
			end
			local sql = string.format("insert into s_big_record (clubid,gameid,uid,score,data,deskid,beginTime,endTime,selectTime,presonNum,gameNum,houseOwner,time,houseOwnerUid,isBigWin)values(%d,%d,%d,%d,'%s',%d,'%s','%s','%s', %d, '%s', '%s',%d,%d,%d)",deskInfo.conf.clubid, deskInfo.conf.gameid, user.uid, user.score, cjson.encode(recordData), deskInfo.conf.deskId, beginTime, os.date("%m-%d %H:%M:%S", os.time()), os.date("%Y-%m-%d", os.time()), deskInfo.conf.seat, deskInfo.conf.gamenum, deskInfo.conf.createUserInfo.playername, os.time(),deskInfo.conf.createUserInfo.uid,isBigWin)
			skynet.call(".mysqlpool", "lua", "execute", sql)
		end
	end
end

-- 给该桌子放置一副已经打乱的牌
local function setDeskBase()
	local dcards = {}
	for i = 1,9 do
		for j = 1,4 do
			table.insert(dcards,i)
		end
	end

	for i = 11,19 do
		for j = 1,4 do
			table.insert(dcards,i)
		end
	end
	for i = 21,29 do
		for j = 1,4 do
			table.insert(dcards,i)
		end
	end
	
	for i = 1,4 do
		table.insert(dcards,35)
	end

	new_card = table.copy(dcards)
	local value = 1
	local swap = 1
	local l = #new_card
	for i = 1,l do
		local x = l - i
		local rv = random_value(x)
		if x == 0 then
			rv = 0
		end
		value = i + rv
		swap = new_card[i]
		new_card[i] = new_card[value]
		new_card[value] = swap
	end
end



local function getNextSeat(seat)
	local nseat = seat + 1
	if nseat > deskInfo.conf.curseat then
		nseat = 1
	end
	return nseat
end

local function getShangSeat(seat)
	local nseat = seat - 1
	if nseat == 0 then
		nseat = deskInfo.conf.curseat
	end
	return nseat
end

local function getNextUser(seat)
	local seat = getNextSeat(seat)
	local user = seleteUserInfo(seat,"seat")
	return user
end

local function restartTime(time)
	deskInfo.time = time
	curTime = os.time()
end

local function restartUserTime(user,time)
	user.time = time
	user.curTime = os.time() + time
end

local function getSyTime(time)
	local syTime = time - (os.time() - curTime)
	deskInfo.time = syTime
end

local function getUserSyTime(uid,time)
	local user = seleteUserInfo(uid,"uid")
	local syTime = user.curTime - os.time()
	user.time = syTime
end

-- 统计相同牌的值
function getXtCardVluse(cards)
    local valurNum = {}
    for _,card in pairs(cards) do
        if not valurNum[card] then
            valurNum[card] = 0
        end
    end
    --可能不是有序的重新排序
    local tmp_cards1 = {}
    local tmpCards = table.copy(cards)
    for _,card in pairs(tmpCards) do
        table.insert(tmp_cards1,card)
    end
    local tmp_cards = table.copy(tmp_cards1)
    for i = 1,#tmp_cards do         
         for j = 1,#tmp_cards1 do
            if tmp_cards[i] == tmp_cards1[j] then
                tmp_cards[i] = 0
                local value = tmp_cards1[i]          
                valurNum[value] = valurNum[value] + 1
            end
         end
    end
    return valurNum
end

local function handInCardsSort(user)
	table.sort(user.handInCards,function(a,b) return a < b end)
	local tmpHandInCards = {}
	for i = 1, #user.handInCards do
		if user.handInCards[i] == 35 then
			table.insert(tmpHandInCards,user.handInCards[i]) 
		end
	end
	for i = 1, #user.handInCards do
		if user.handInCards[i] ~= 35 then
			table.insert(tmpHandInCards,user.handInCards[i])
		end
	end

	user.handInCards = tmpHandInCards
	print("--user.handInCards--",user.handInCards)
end

-- 当把游戏结束
local function global_over()
	deskInfo.smallState = 0
	deskInfo.smallBeginTime = ""
	deskInfo.actionInfo = {iswait = 0,waitList = {},curaction = {seat = 0, type = 0, card = 0, source = 0},nextaction = {seat = 0, type = 0}}
	for _,user in pairs(deskInfo.users) do
		if usersAutoFuc[user.seat] then 
			usersAutoFuc[user.seat](user.seat)
		end
		user.handInCards = {}
		user.tingPaiInfo = {}
		user.qipai = {}
		user.gangpai = {}
		user.pengpai = {}
		user.state = 0
		user.roundScore = 0
		CMD.userSetAutoState("autoReady",timeout[1]*100,user.seat)
	end
	waitAction = {}
end
 
-- 当把游戏结束
local function big_over()
	for _,user in pairs(deskInfo.users) do
		pcall(cluster.call, user.cluster_info.server, user.cluster_info.address, "deskBack", PDEFINE.GAME_TYPE.MJ_HONGZ) --释放桌子对象
		pcall(cluster.call, "clubs", ".clubsmgr", "deltelUser", user.uid, deskInfo.conf.clubid,deskInfo.conf.deskId,true)
	end
	deskInfo.users = {}
	deskInfo.smallState = 0
	deskInfo.bigState = 0
	deskInfo.bankerInfo = {uid = 0, count = 1, seat = 0}
	deskInfo.actionInfo = {iswait = 0,waitList = {},curaction = {seat = 0, type = 0, card = 0, source = 0},nextaction = {seat = 0, type = 0}}
	pcall(cluster.call, "game", ".dsmgr", "recycleAgent", skynet.self(), deskInfo.conf.deskId)
end


local function hupaiBance(huPaiInfo)
	closeAllTimer()
	local huser = seleteUserInfo(huPaiInfo.hseat,"seat")
	local noty_retobj  = {}
	noty_retobj.c      = PDEFINE.NOTIFY.NOTIFY_HZ_HUPAI
	noty_retobj.code   = PDEFINE.RET.SUCCESS
	noty_retobj.gameid = deskInfo.gameid
	noty_retobj.seat = huPaiInfo.hseat
	noty_retobj.hcard = huPaiInfo.hcard
	noty_retobj.hupaiType = huPaiInfo.htype
	noty_retobj.diPai = new_card
	noty_retobj.buck = deskInfo.bankerInfo.uid
	noty_retobj.smallState = deskInfo.smallState
	noty_retobj.overTime = os.date("%Y-%m-%d %H:%M:%S", os.time())
	
	local bird = {}
	if huPaiInfo.htype > 0 then
		local birdnum = 0
		if deskInfo.conf.param1 > 0 then
			for i=1, deskInfo.conf.param1 do
				if new_card[i] then
					local niao = new_card[i]%10
					if niao == 1 or niao == 5 or niao == 9 then
						birdnum = birdnum + 2
						table.insert(bird,new_card[i])
					end
				end
			end
		end
		if birdnum == 0 then birdnum = 1 end
		huser.roundScore = (huser.roundScore + 2)*birdnum
		huser.score = huser.score + huser.roundScore
		for _,muser in pairs(deskInfo.users) do
			if muser.seat ~= huPaiInfo.hseat then
				muser.roundScore = (muser.roundScore - 2)*birdnum
				muser.score = muser.score + muser.roundScore
			end
			handInCardsSort(muser)
		end
	
		huser.zimoCount = huser.zimoCount + 1
		delteHandIncards(huser,huPaiInfo.hcard)
		modifBankerInfo(huser.uid,huser.seat)
		noty_retobj.users   = deskInfo.users
		gameRecord(1)
	else--流局
		if not huPaiInfo.isdissolve then
			local nextSeat = getNextSeat(deskInfo.bankerInfo.seat)
			local nextUser = seleteUserInfo(nextSeat,"seat")
			modifBankerInfo(nextUser.uid,nextUser.seat)
		end

		for _,muser in pairs(deskInfo.users) do
			muser.score = muser.score + muser.roundScore
			handInCardsSort(muser)
		end
		noty_retobj.users   = deskInfo.users
		gameRecord(1)
	end
	noty_retobj.bird = bird
	broadcastDesk(cjson.encode(noty_retobj))
	if deskInfo.round == deskInfo.conf.gamenum or huPaiInfo.isdissolve then
		local userList = {}
		for _,user in pairs(deskInfo.users) do
			local info = {}
			info.uid = user.uid
			info.playername = user.playername
			info.usericon = user.usericon
			info.zimoCount = user.zimoCount --自摸次数
			info.angangCount = user.angangCount --暗杠次数 
			info.mingangCount = user.mingangCount  --明杠次数
			info.jiegangCount = user.jiegangCount --接杠次数
			info.score = user.score
			table.insert(userList,info)
		end
		local noty_retobj  = {}
		noty_retobj.c      = PDEFINE.NOTIFY.NOTIFY_HZ_OVER
		noty_retobj.code   = PDEFINE.RET.SUCCESS
		noty_retobj.gameid = deskInfo.gameid
		noty_retobj.overTime = os.date("%Y-%m-%d %H:%M:%S", os.time())
		noty_retobj.createUser = deskInfo.conf.createUserInfo
		noty_retobj.users   = userList
		broadcastDesk(cjson.encode(noty_retobj))
		
		if deskInfo.smallState == 1 then
			gameRecord(2)
		end
		big_over()
		--通知桌子结束--TODO
	else
		global_over()
	end
	
end


--断线玩家碰完牌后是否全是红中
local function CheckAllHz(pcard,cards)
	local tmpCards = table.copy(cards)
	local count = 0
	if pcard then
		for i,card in pairs(tmpCards) do
			if card == pcard then
				tmpCards[i] = nil
				count = count + 1
				if count == 2 then
					break
				end
			end
		end
	end
	local flag = 1
	print("----tmpCards-------",tmpCards)
	for i,card in pairs(tmpCards) do
		if card ~= 35 then
			flag = 0
			break
		end
	end
	return flag
end

-- 出牌检测其它玩家是否能碰跟杠
local function checkPengGangHu(seat,pcard,ptype,nextSeat)
	if ptype == hongzhongtool.cardType.put then
		print("---nextSeat---",nextSeat)
		print("---pcard---",pcard)
		local nextUser = seleteUserInfo(nextSeat,"seat")
		print("---nextUser.handInCards---",nextUser.handInCards)
		local num = hongzhongtool.getValueCount(nextUser.handInCards, pcard)
		print("---num---",num)
		if num >= 2 then
			deskInfo.actionInfo.waitList[nextSeat] = {}
			if num == 2 then
				local info = {}
				info.type = hongzhongtool.cardType.guo
				info.seat = nextSeat
				table.insert(deskInfo.actionInfo.waitList[nextSeat],info)

				local info = {}
				info.type = hongzhongtool.cardType.peng
				info.seat = nextSeat
				info.card = pcard
				table.insert(deskInfo.actionInfo.waitList[nextSeat],info)
			end
			if num == 3 then
				local info = {}
				info.type = hongzhongtool.cardType.guo
				info.seat = nextSeat
				table.insert(deskInfo.actionInfo.waitList[nextSeat],info)

				local info = {}
				info.type = hongzhongtool.cardType.gang
				info.seat = nextSeat
				info.card = pcard
				table.insert(deskInfo.actionInfo.waitList[nextSeat],info)
			end
		end
	elseif ptype == hongzhongtool.cardType.draw then
		local ownUser = seleteUserInfo(seat,"seat")
		local num = hongzhongtool.getValueCount(ownUser.handInCards, pcard)
		if num == 4 then
			deskInfo.actionInfo.waitList[ownUser.seat] = {}
			if num == 4 then
				local info = {}
				info.type = hongzhongtool.cardType.guo
				info.seat = ownUser.seat
				table.insert(deskInfo.actionInfo.waitList[ownUser.seat],info)
				
				local info = {}
				info.type = hongzhongtool.cardType.gang
				info.seat = ownUser.seat
				info.card = pcard
				table.insert(deskInfo.actionInfo.waitList[ownUser.seat],info)
			end
		end
		--检测胡牌 --TODO
		local huCard = hongzhongtool.checkIsHu(ownUser.handInCards,pcard)
		if huCard then
			if deskInfo.actionInfo.waitList[ownUser.seat] == nil then
				deskInfo.actionInfo.waitList[ownUser.seat] = {}
				local info = {}
				info.type = hongzhongtool.cardType.guo
				info.seat = ownUser.seat
				table.insert(deskInfo.actionInfo.waitList[ownUser.seat],info)
			end
			local info = {}
			info.type = hongzhongtool.cardType.hupai
			info.seat = ownUser.seat
			info.card = huCard
			table.insert(deskInfo.actionInfo.waitList[ownUser.seat],info)
		end
	end
end

local function draw(seat)
	local user = seleteUserInfo(seat,"seat")
	if #new_card == deskInfo.conf.param1 then
		local huPaiInfo = {}
		huPaiInfo.hseat = deskInfo.actionInfo.curaction.seat
		huPaiInfo.hcard = deskInfo.actionInfo.curaction.card
		huPaiInfo.htype = hongzhongtool.HUPAI_TYPE.liuju
		hupaiBance(huPaiInfo)
		return
	end

	local drawCard = table.remove(new_card)
	deskInfo.actionInfo.iswait = 0
	deskInfo.actionInfo.waitList = {}
	deskInfo.nextaction = {seat = 0, type = 0}
	table.insert(user.handInCards,drawCard)
	
	deskInfo.actionInfo.curaction.seat = user.seat
	deskInfo.actionInfo.curaction.card = drawCard
	deskInfo.actionInfo.curaction.type = hongzhongtool.cardType.drawCard
	deskInfo.actionInfo.curaction.source = user.seat

	checkPengGangHu(seat,drawCard,hongzhongtool.cardType.draw)
	print("--------draw-----seat--",user.seat)
    print("--------draw-------",deskInfo.actionInfo.waitList)
	if table.size(deskInfo.actionInfo.waitList) == 0 then
		deskInfo.actionInfo.iswait = 0
		deskInfo.actionInfo.nextaction = {seat = seat, type = hongzhongtool.cardType.put}
	else
		deskInfo.actionInfo.iswait = 1
	end
	local noty_retobj  = {}
	noty_retobj.c      = PDEFINE.NOTIFY.NOTIFY_HZ_DRAW
	noty_retobj.code   = PDEFINE.RET.SUCCESS
	noty_retobj.gameid = deskInfo.gameid
	noty_retobj.seat   = user.seat
	noty_retobj.pulicCardsCnt = #new_card
	noty_retobj.actionInfo = deskInfo.actionInfo

	

	for _, muser in pairs(deskInfo.users) do
		if deskInfo.actionInfo.iswait == 1 then
			if deskInfo.actionInfo.waitList[muser.seat] then
				local actionInfo = {}
				actionInfo.curaction = deskInfo.actionInfo.curaction
				actionInfo.nextaction = deskInfo.actionInfo.nextaction
				actionInfo.iswait = 1
				actionInfo.waitList = deskInfo.actionInfo.waitList[muser.seat]
				noty_retobj.actionInfo = actionInfo
			else
				local actionInfo = {}
				actionInfo.curaction = deskInfo.actionInfo.curaction
				actionInfo.nextaction = deskInfo.actionInfo.nextaction
				actionInfo.iswait = 1
				actionInfo.waitList = {}
				noty_retobj.actionInfo = actionInfo
			end
		end
		if seat ~= muser.seat then
			noty_retobj.actionInfo.curaction.card = 0
		else
			noty_retobj.actionInfo.curaction.card = drawCard
		end

		if muser.ofline == 0 then
			pcall(cluster.call, muser.cluster_info.server, muser.cluster_info.address, "sendToClient", cjson.encode(noty_retobj))
		end
	end
end



-- 取出牌
local function getCard(buck) --庄家多抓一张
	setDeskBase()
	local userscard = {}
	for i = 1, 2 do
		userscard[i] = {}
	end

	for i = 1 ,2 do
		for j=1,13 do 
			table.insert(userscard[i],new_card[j])
			table.remove(new_card,j)
		end
		if buck == i then --庄家多发一张
			table.insert(userscard[i],new_card[1])
			table.remove(new_card,1)
		end
	end
	return userscard
end


function CMD.exit()
	collectgarbage("collect")
	skynet.exit()
end


local function autoPut(seat)
	
end

local function autoPass(seat)
	
end

local function autoPeng(seat)

end

local function user_set_timeout(ti, f,parme)
	local function t()
	    if f then 
	    	f(parme)
	    end
	 end
	skynet.timeout(ti, t)
	return function(parme) f=nil end
end


function CMD.cancelAuto(source,msg)
	local recvobj  = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local user = seleteUserInfo(uid,"uid")
	user.autoc = 0
	local retobj  = {}
	retobj.c      = PDEFINE.NOTIFY.NOTIFY_HZ_CANCE
	retobj.code   = PDEFINE.RET.SUCCESS
	retobj.gameid = deskInfo.gameid
	retobj.seat   = user.seat
	retobj.uid   = uid
	broadcastDesk(cjson.encode(retobj))
	return PDEFINE.RET.SUCCESS 
end

-- 碰 
function CMD.peng(source,msg)
	local recvobj  = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local pcard = deskInfo.actionInfo.curaction.card
	local source = deskInfo.actionInfo.curaction.seat
	local user = seleteUserInfo(uid,"uid")

	local num = hongzhongtool.getValueCount(user.handInCards, pcard)
	if num < 2 then
		return PDEFINE.RET.ERROR.ERROR_PENG_ERROR
	end
	delteHandIncards(user,pcard)
	delteHandIncards(user,pcard)

	deskInfo.actionInfo.curaction.seat = user.seat
	deskInfo.actionInfo.curaction.card = pcard
	deskInfo.actionInfo.curaction.type = hongzhongtool.cardType.peng
	deskInfo.actionInfo.curaction.source = source
	deskInfo.actionInfo.nextaction = {seat = user.seat, type = hongzhongtool.cardType.put}
	deskInfo.actionInfo.iswait = 0
	deskInfo.actionInfo.waitList = {}
	table.insert(user.pengpai,pcard)

	local noty_retobj    = {}
	noty_retobj.code     = PDEFINE.RET.SUCCESS
	noty_retobj.c        = PDEFINE.NOTIFY.NOTIFY_HZ_PENG
	noty_retobj.seat      = user.seat
	noty_retobj.uid   = user.uid
	noty_retobj.card   = pcard
	noty_retobj.time = timeout[1]
	noty_retobj.actionInfo = deskInfo.actionInfo
	broadcastDesk(cjson.encode(noty_retobj))
	user.autoc = 0
	--CMD.userSetAutoState("autoPassOrPut",timeout[2]*100,uid)
	return PDEFINE.RET.SUCCESS
end


-- 打牌
function CMD.put(source,msg)
	local recvobj  = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local pcard = math.floor(recvobj.card)

	if pcard == 35 then
		return PDEFINE.RET.ERROR.NO_ACTION_ERROR
	end

	local user = seleteUserInfo(uid,"uid")
	--判断打牌者是否这个用户
	if deskInfo.actionInfo.nextaction.seat ~= user.seat or deskInfo.actionInfo.nextaction.type ~= hongzhongtool.cardType.put then
		return PDEFINE.RET.ERROR.NO_ACTION_ERROR
	end

	if usersAutoFuc[uid] then
		usersAutoFuc[uid](uid)
	end
	user.autoc = 0

	if delteHandIncards(user,pcard) then
		deskInfo.actionInfo.curaction.seat = user.seat
		deskInfo.actionInfo.curaction.card = pcard
		deskInfo.actionInfo.curaction.type = hongzhongtool.cardType.put
		deskInfo.actionInfo.curaction.source = user.seat
	else
		return PDEFINE.RET.ERROR.NO_ACTION_ERROR
	end
	handInCardsSort(user)	
	notyTingPaiInfo(user)
	-- 通知其它玩家打牌
	local noty_retobj  = {}
	noty_retobj.c      = PDEFINE.NOTIFY.NOTIFY_HZ_PUT
	noty_retobj.code   = PDEFINE.RET.SUCCESS
	noty_retobj.gameid = deskInfo.gameid
	noty_retobj.seat   = user.seat
	noty_retobj.card = pcard

    local nextSeat = getNextSeat(user.seat)
    checkPengGangHu(user.seat,pcard,hongzhongtool.cardType.put,nextSeat)
    print("--------put-----seat--",user.seat)
    print("--------put-------",deskInfo.actionInfo.waitList)
    if table.size(deskInfo.actionInfo.waitList) == 0 then
    	deskInfo.actionInfo.iswait = 0
    	deskInfo.actionInfo.nextaction = {seat = nextSeat, type = hongzhongtool.cardType.draw}
    else
    	deskInfo.actionInfo.iswait = 1
    	deskInfo.actionInfo.nextaction = {seat = 0, type = 0}
    end
    
    if deskInfo.actionInfo.iswait == 1 then
	    for _, muser in pairs(deskInfo.users) do
			if deskInfo.actionInfo.waitList[muser.seat] then
				local actionInfo = {}
				actionInfo.curaction = deskInfo.actionInfo.curaction
				actionInfo.nextaction = deskInfo.actionInfo.nextaction
				actionInfo.iswait = 1
				actionInfo.waitList = deskInfo.actionInfo.waitList[muser.seat]
				noty_retobj.actionInfo = actionInfo
				if muser.ofline == 0 then
					pcall(cluster.call, muser.cluster_info.server, muser.cluster_info.address, "sendToClient", cjson.encode(noty_retobj))
				end
			else
				local actionInfo = {}
				actionInfo.curaction = deskInfo.actionInfo.curaction
				actionInfo.nextaction = deskInfo.actionInfo.nextaction
				actionInfo.iswait = 1
				actionInfo.waitList = {}
				noty_retobj.actionInfo = actionInfo
				if muser.ofline == 0 then
					pcall(cluster.call, muser.cluster_info.server, muser.cluster_info.address, "sendToClient", cjson.encode(noty_retobj))
				end
			end
		end
	else
		table.insert(user.qipai,pcard)
		noty_retobj.actionInfo = deskInfo.actionInfo
		broadcastDesk(cjson.encode(noty_retobj))

		skynet.sleep(100)
		draw(nextSeat)
	end

	return PDEFINE.RET.SUCCESS
end

-- 杠牌 
function CMD.gang(source,msg)
	local recvobj  = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local gcard = deskInfo.actionInfo.curaction.card
	local source = deskInfo.actionInfo.curaction.seat
	local user = seleteUserInfo(uid,"uid")

	local num = hongzhongtool.getValueCount(user.handInCards,gcard)
	local gangtype = 0
	local addscore = 0
	if num == 4 then
		gangtype = hongzhongtool.cardType.agang
		addscore = addscore + 2
		user.angangCount = user.angangCount + 1
		delteHandIncards(user,gcard)
		delteHandIncards(user,gcard)
		delteHandIncards(user,gcard)
		delteHandIncards(user,gcard)
	elseif num < 3 then
		local peng = false
		for i,card in pairs(user.pengpai) do
			if card == gcard then
				peng = true
				table.remove(user.pengpai,i)
				break
			end
		end
		if peng then
			if deskInfo.actionInfo.curaction.type == hongzhongtool.cardType.draw and deskInfo.actionInfo.curaction.seat == user.seat then
				gangtype = hongzhongtool.cardType.mgang
				addscore = addscore + 1
				user.mingangCount = user.mingangCount + 1
			else
				return PDEFINE.RET.ERROR.ERROR_GANG_ERROR
			end
		else
			return PDEFINE.RET.ERROR.ERROR_GANG_ERROR
		end
	elseif num == 3 then
		if deskInfo.actionInfo.curaction.type == hongzhongtool.cardType.put then
			gangtype = hongzhongtool.cardType.jgang
			addscore = addscore + 3
			user.jiegangCount = user.jiegangCount + 1
			delteHandIncards(user,gcard)
			delteHandIncards(user,gcard)
			delteHandIncards(user,gcard)
		else
			return PDEFINE.RET.ERROR.ERROR_GANG_ERROR
		end
	else
		return PDEFINE.RET.ERROR.ERROR_GANG_ERROR
	end

	for _,user in pairs(deskInfo.users) do
		if user.uid == uid then
			user.roundScore = user.roundScore + addscore
		else
			user.roundScore = user.roundScore - addscore
		end
	end

	deskInfo.actionInfo.curaction.seat = user.seat
	deskInfo.actionInfo.curaction.card = gcard
	deskInfo.actionInfo.curaction.type = gangtype
	deskInfo.actionInfo.curaction.source = source
	deskInfo.actionInfo.nextaction = {seat = 0, type = 0}
	deskInfo.actionInfo.iswait = 0
	deskInfo.actionInfo.waitList = {}
	table.insert(user.gangpai,gcard)


	local noty_retobj    = {}
	noty_retobj.code     = PDEFINE.RET.SUCCESS
	noty_retobj.c        = PDEFINE.NOTIFY.NOTIFY_HZ_GANG
	noty_retobj.seat      = user.seat
	noty_retobj.uid   = user.uid
	noty_retobj.card   = gcard
	noty_retobj.time = timeout[1]
	noty_retobj.actionInfo = deskInfo.actionInfo
	broadcastDesk(cjson.encode(noty_retobj))
	user.autoc = 0
	skynet.sleep(100)
	draw(user.seat)
	--CMD.userSetAutoState("autoPassOrPut",timeout[2]*100,uid)
	return PDEFINE.RET.SUCCESS
end

-- 过
function CMD.pass(source,msg)
	local recvobj  = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local user = seleteUserInfo(uid,"uid")
	
	if deskInfo.actionInfo.curaction.seat ~= user.seat then 
		if usersAutoFuc[uid] then
			usersAutoFuc[uid](uid)
		end
		deskInfo.actionInfo.curaction.seat = 0
		deskInfo.actionInfo.curaction.card = 0
		deskInfo.actionInfo.curaction.type = 0
		deskInfo.actionInfo.curaction.source = 0

		deskInfo.actionInfo.nextaction.seat = 0
		deskInfo.actionInfo.curaction.type = 0

		deskInfo.actionInfo.iswait = 0
		deskInfo.actionInfo.waitList = {}
		-- 通知其它玩家打牌
		local noty_retobj  = {}
		noty_retobj.c      = PDEFINE.NOTIFY.NOTIFY_HZ_PASS
		noty_retobj.code   = PDEFINE.RET.SUCCESS
		noty_retobj.gameid = deskInfo.gameid
		noty_retobj.seat   = user.seat
		noty_retobj.actionInfo = deskInfo.actionInfo
		broadcastDesk(cjson.encode(noty_retobj))
		skynet.sleep(100)
		draw(user.seat)
	else

		deskInfo.actionInfo.curaction.seat = 0
		deskInfo.actionInfo.curaction.card = 0
		deskInfo.actionInfo.curaction.type = 0
		deskInfo.actionInfo.curaction.source = 0

		deskInfo.actionInfo.nextaction.seat = user.seat
		deskInfo.actionInfo.nextaction.type = hongzhongtool.cardType.put

		deskInfo.actionInfo.iswait = 0
		deskInfo.actionInfo.waitList = {}
		-- 通知其它玩家打牌
		local noty_retobj  = {}
		noty_retobj.c      = PDEFINE.NOTIFY.NOTIFY_HZ_PASS
		noty_retobj.code   = PDEFINE.RET.SUCCESS
		noty_retobj.gameid = deskInfo.gameid
		noty_retobj.seat   = user.seat
		noty_retobj.actionInfo = deskInfo.actionInfo
		skynet.sleep(100)
		broadcastDesk(cjson.encode(noty_retobj))
	end
	return PDEFINE.RET.SUCCESS
end

-- 胡牌
function CMD.hupai(source,msg)
	local recvobj  = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local user = seleteUserInfo(uid,"uid")

	local hcard = deskInfo.actionInfo.curaction.card
	local ret,htype = hongzhongtool.getHType(user,hcard)
	if not ret then
		return PDEFINE.RET.ERROR.ERROR_HUPAI_ERROR
	end
	
	local huPaiInfo = {}
	huPaiInfo.hseat = user.seat
	huPaiInfo.hcard = hcard
	huPaiInfo.htype = htype
	hupaiBance(huPaiInfo)

	return PDEFINE.RET.SUCCESS
end


-- 准备游戏
local function autoReady(seat)
	local user = seleteUserInfo(seat,"seat")
	if deskInfo.smallState == 1 then
		return PDEFINE.RET.SUCCESS 
	end
	if user.state == 1 then
        return PDEFINE.RET.SUCCESS
    end
    if usersAutoFuc[seat] then 
		usersAutoFuc[seat](seat)
	end
	user.state = 1
	local retobj    = {}
    retobj.code     = PDEFINE.RET.SUCCESS
    retobj.c        = PDEFINE.NOTIFY.NOTIFY_READY
    retobj.uid      = user.uid
    retobj.seat   = user.seat
    broadcastDesk(cjson.encode(retobj))
    if #deskInfo.users == deskInfo.conf.seat then
	    for _, userReady in pairs(deskInfo.users) do  --判断所有玩家是否都已经准备
	        if userReady.state ~= 1 then
	            return PDEFINE.RET.SUCCESS
	        end
	    end
	    CMD.startGame()
	end
    return PDEFINE.RET.SUCCESS
end

function CMD.userSetAutoState(autoType,autoTime,seat)
	if deskInfo.conf.param2 == 1 then
		if usersAutoFuc[seat] then 
			usersAutoFuc[seat](seat)
		end
		local user = seleteUserInfo(seat,"seat")
		if user.autoc >= 2 then
	    	autoTime = timeout[5]*100
	    end

		if autoType == "autoPass" then
			usersAutoFuc[seat] = user_set_timeout(autoTime,autoPass,seat)
		elseif autoType == "autoReady" then
			usersAutoFuc[seat] = user_set_timeout(autoTime,autoReady,seat)
		elseif autoType == "autoPut" then
	        usersAutoFuc[seat] = user_set_timeout(autoTime, autoPut, seat)
	    elseif autoType == "autoPeng" then
	        usersAutoFuc[seat] = user_set_timeout(autoTime, autoPeng, seat)
	    end
	end
end



--更新玩家的桌子信息
function CMD.updateUserClusterInfo(source, uid, agent)
    local user = seleteUserInfo(uid,"uid")
    if nil ~= user and user.cluster_info then
        user.cluster_info.address = agent
    end
end

-- 开始游戏
function CMD.startGame() --2种开始方式  庄家设置也不一样 
	if deskAutoFuc then deskAutoFuc() end
	--restartTime(timeout[2]) --重置桌子时间
	if deskInfo.bankerInfo.uid == 0 then
		initBankerInfo()
	end
	initDissolveInfo()
	getActionInfo()
	local notify_retobj = {}
	notify_retobj.c = PDEFINE.NOTIFY.start
	notify_retobj.code   = PDEFINE.RET.SUCCESS
    notify_retobj.gameid = PDEFINE.GAME_TYPE.MJ_HONGZ
    notify_retobj.bankerInfo = deskInfo.bankerInfo
    notify_retobj.actionInfo = deskInfo.actionInfo
	local usersCard = getCard(deskInfo.bankerInfo.seat)
	notify_retobj.cardcnt   = #new_card
	deskInfo.cardcnt = #new_card

	waitAction = {}

	-- if #usersCard[1] == 15 then
	-- 	usersCard[1] = {102,103,103,104,104,105,105,203,203,205}
	-- 	usersCard[2] = {209,109,109,108,108,205,205,230}
	-- 	usersCard[3] = {209,109,109,108,108,205,205,230}
	-- 	usersCard[4] = {103,108,109,209,209,205,205,230}
	-- else
	-- 	usersCard[1] = {102,103,103,104,104,105,105,203,203,205}
	-- 	usersCard[2] = {209,109,109,108,108,205,205,230}
	-- 	usersCard[3] = {209,109,109,108,108,205,205,230}
	-- 	usersCard[4] = {103,108,109,209,209,205,205,230}
	-- end
	
	--   if #usersCard[1] == 15 then
	--  	usersCard[1] = {105,105,105,209,102,104}
	-- 	 usersCard[2] = {206,206,206,102,105}
	--   else
	--   	usersCard[1] =  {206,206,206,102,105}
	--   	usersCard[2] = {105,105,105,209,102,104}
	--   end
 --      new_card = {209,108,105,205,105,105,206,206}
 --   	if #usersCard[1] == 14 then
	-- 	usersCard[1] = {1,2,3,4,4,4,5,5,5,35,22,23,14,15}
	-- 	usersCard[2] = {1,2,3,4,14,24,5,15,25,11,12,13,14}
	-- else
	-- 	usersCard[1] = {1,2,3,4,14,24,5,15,25,11,12,13,14}
	-- 	usersCard[2] = {1,2,3,4,4,4,5,5,5,35,22,23,14,15}
	-- end
	-- new_card = {35,35,35,35}
	for index,user in pairs(deskInfo.users) do
		user.time = 0
		user.curTime = 0
		user.qipai = {} --初始化弃牌区
		user.gangpai = {} --初始化杠牌区
		user.pengpai = {} --初始化碰牌区
		user.score = user.score + user.roundScore
		user.roundScore = 0
		user.handInCards =usersCard[user.seat]
		user.state = 2
		handInCardsSort(user)
	end

	deskInfo.smallBeginTime = os.date("%Y-%m-%d %H:%M:%S", os.time())
		
	if deskInfo.round == 0 then
		beginTime = os.date("%m-%d %H:%M:%S", os.time())
	end
	deskInfo.round = deskInfo.round + 1
	for index,user in pairs(deskInfo.users) do
		notify_retobj.seat = user.seat
		notify_retobj.round = deskInfo.round
		notify_retobj.score = user.score
		for _,muser in pairs(deskInfo.users) do
			if user.uid == muser.uid then
				notify_retobj.handInCards = user.handInCards
			else
				local tmpHandInCards = {}
				for i = 1,#user.handInCards do
					table.insert(tmpHandInCards,0)
				end
				notify_retobj.handInCards = tmpHandInCards
			end
			if muser.ofline == 0 then
				pcall(cluster.call, muser.cluster_info.server, muser.cluster_info.address, "sendToClient", cjson.encode(notify_retobj))
			end
		end
	end

	for _, muser in pairs(deskInfo.users) do
		if deskInfo.actionInfo.nextaction.seat ~= muser.seat then
			notyTingPaiInfo(muser)
		end
	end

	if deskInfo.bigState == 0 then
		deskInfo.bigState = 1
	end
	deskInfo.smallState = 1
	
	
	--CMD.userSetAutoState("autoPut",timeout[1]*100,deskInfo.actionInfo.nextaction.seat)
	
end



-- 准备游戏
function CMD.ready(source,msg)
	local recvobj  = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local user = seleteUserInfo(uid,"uid")
	user.autoc = 0
	if deskInfo.smallState == 1 then
		return PDEFINE.RET.SUCCESS 
	end
	
	if user.state == 1 then
        return PDEFINE.RET.SUCCESS
    end
    if usersAutoFuc[user.seat] then 
		usersAutoFuc[user.seat](user.seat)
	end
	if deskInfo.bigState == 0 then
    	pcall(cluster.call, "clubs", ".clubsmgr", "userReady", user.uid,deskInfo.conf.clubid,deskInfo.conf.deskId)
    end
	user.state = 1
	local retobj    = {}
    retobj.code     = PDEFINE.RET.SUCCESS
    retobj.c        = PDEFINE.NOTIFY.NOTIFY_READY
    retobj.uid      = uid
    retobj.seat   = user.seat
    broadcastDesk(cjson.encode(retobj))
    if #deskInfo.users == deskInfo.conf.seat then
	    for _, userReady in pairs(deskInfo.users) do  --判断所有玩家是否都已经准备
	        if userReady.state ~= 1 then
	            return PDEFINE.RET.SUCCESS
	        end
	    end

	    CMD.startGame()
	end
    return PDEFINE.RET.SUCCESS
end

-- 返回到大厅 需要下发当前的桌子ID给客户端 然它定位当前哪个桌子上,也是判断自己当前是已经进入到了桌子里
function CMD.backClubHall(source,msg)
	local recvobj  = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local user = seleteUserInfo(uid,"uid")
	user.isBackClubHall = true
	local retobj = {}
	retobj.c      = math.floor(recvobj.c)
    retobj.code  = PDEFINE.RET.SUCCESS
    retobj.deskId = deskInfo.conf.deskId
    return resp(retobj)
end


local function autoDissolve(isTimeOut)
	local noty_retobj    = {}
	noty_retobj.c        = PDEFINE.NOTIFY.succeddissolve
	noty_retobj.code     = PDEFINE.RET.SUCCESS
	noty_retobj.isShowJieSuan = isTimeOut
	broadcastDesk(cjson.encode(noty_retobj))
	if isTimeOut == 1 then 
		local huPaiInfo = {}
		huPaiInfo.hseat = deskInfo.actionInfo.curaction.seat
		huPaiInfo.hcard = deskInfo.actionInfo.curaction.card
		huPaiInfo.htype = hongzhongtool.HUPAI_TYPE.liuju
		huPaiInfo.isdissolve = true
		hupaiBance(huPaiInfo)
	else
		big_over()
	end
end

-- 加入桌子
function CMD.hallJoin(source,uid,cluster_info,ip,lat,lng,state)
	return cs(function ()
		if state == 0 then
			return PDEFINE.RET.ERROR.CLUB_IS_FREEZE
		end
		local user = seleteUserInfo(uid,"uid")
		if user then
			local tmp_deskInfo = table.copy(deskInfo)
			for i,muser in pairs(tmp_deskInfo.users) do
				if muser.uid ~= uid then
					tmp_deskInfo.users[i].handInCards = nil
				end
			end
			return PDEFINE.RET.SUCCESS,tmp_deskInfo
		end

		if deskInfo.conf.distance == 1 then
			if not hongzhongtool.checkDistance(lat,lng,deskInfo.users) then
				return PDEFINE.RET.ERROR.DISTANCE_EXIST
			end
		end

		if deskInfo.conf.ipcheck == 1 then
			if not hongzhongtool.checkIp(ip,deskInfo.users) then
				return PDEFINE.RET.ERROR.CHECK_IP
			end
		end

		if deskInfo.conf.curseat == deskInfo.conf.seat then
			return PDEFINE.RET.ERROR.SEATID_EXIST
		end

		local playerInfo = getPlayerInfo(uid)

		local seat = getSeatId()
		if not seat then
	 		return PDEFINE.RET.ERROR.SEATID_EXIST
	 	end
	 	if #deskInfo.users == 0 then
	 		deskAutoFuc = user_set_timeout(PDEFINE_GAME.GAME_PARAM.DISS_TIME*100,autoDissolve,0)
	 	end
	 	deskInfo.conf.curseat = deskInfo.conf.curseat + 1
		local userInfo = {}
		userInfo.tingPaiInfo = {}
		userInfo.cluster_info = cluster_info
		userInfo.score = 0 --总分数
		userInfo.roundScore = 0 --每一局的分数
		userInfo.sex = playerInfo.sex
		userInfo.usericon = playerInfo.usericon
		userInfo.playername = serializePlayername(playerInfo.playername)
		userInfo.zimoCount = 0  --自摸次数
		userInfo.angangCount = 0 --暗杠次数 
		userInfo.mingangCount = 0  --明杠次数
		userInfo.jiegangCount = 0 --接杠次数
		userInfo.uid = uid
		userInfo.lat = lat
		userInfo.lng = lng
		userInfo.state = 0
		userInfo.ofline = 0
		userInfo.gangpai = {}
		userInfo.pengpai = {}
		userInfo.qipai = {}
		userInfo.handInCards = {}
		userInfo.autoc = 0
		userInfo.ip = ip
		userInfo.seat = seat
		table.insert(deskInfo.users,userInfo)
		deskInfo.locatingList,gpsColour = hongzhongtool.jisuanXY(deskInfo.users)

		local retobj  = {}
	    retobj.c      = PDEFINE.NOTIFY.join
	    retobj.code   = PDEFINE.RET.SUCCESS
	    retobj.gameid = deskInfo.conf.gameid
	    retobj.deskId   = deskInfo.conf.deskId
	    retobj.gpsColour = gpsColour
	    retobj.user = { uid = uid , state = 0, seat = userInfo.seat, state = userInfo.state,score = userInfo.score, sex = playerInfo.sex, playername = userInfo.playername, usericon= playerInfo.usericon}
	    broadcastDesk(cjson.encode(retobj))
	    --需要去掉其它玩家的手牌
	    user_set_timeout(100,notyGpsColour)
		return PDEFINE.RET.SUCCESS,deskInfo,retobj.user
	end)
end

local function localGetDeskInfo(uid,lat,lng)
	local tmpDeskInfo = {}
	tmpDeskInfo.users = table.copy(deskInfo.users)
	--拿掉其它玩家坎牌跟手牌的值
	for _, user in pairs(tmpDeskInfo.users) do
		if user.uid ~= uid then
			for i = 1,#user.handInCards do
				user.handInCards[i] = 0
			end
		else
			print("-----user.handInCards-----",user.handInCards)
		end
	end
	
	tmpDeskInfo.conf = deskInfo.conf
	tmpDeskInfo.bankerInfo = deskInfo.bankerInfo
	tmpDeskInfo.smallState = deskInfo.smallState
	tmpDeskInfo.bigState = deskInfo.bigState
	tmpDeskInfo.round = deskInfo.round
	tmpDeskInfo.dissolveInfo = deskInfo.dissolveInfo
	tmpDeskInfo.pulicCardsCnt = #new_card
	for _, muser in pairs(deskInfo.users) do
		if uid == muser.uid then
			muser.isBackClubHall = nil
			muser.lat = lat or muser.lat
			muser.lng = lng or muser.lng
			if deskInfo.actionInfo.waitList[muser.seat] then
				local actionInfo = {}
				actionInfo.curaction = deskInfo.actionInfo.curaction
				actionInfo.nextaction = deskInfo.actionInfo.nextaction
				actionInfo.iswait = 1
				actionInfo.waitList = deskInfo.actionInfo.waitList[muser.seat]
				tmpDeskInfo.actionInfo = actionInfo
			else
				local actionInfo = {}
				actionInfo.curaction = deskInfo.actionInfo.curaction
				actionInfo.nextaction = deskInfo.actionInfo.nextaction
				actionInfo.iswait = 1
				actionInfo.waitList = {}
				tmpDeskInfo.actionInfo = actionInfo
			end
			break
		end
	end
	if tmpDeskInfo.dissolveInfo.iStart == 1 then
		tmpDeskInfo.dissolveInfo.distimeoutIntervel = tmpDeskInfo.dissolveInfo.distimeoutBeginTime + timeout[4] - os.time()
	end
	tmpDeskInfo.locatingList = hongzhongtool.jisuanXY(deskInfo.users)
	return tmpDeskInfo
end

function CMD.getDeskInfoClient(source,msg)
	local recvobj = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local retobj = {}
	retobj.c      = math.floor(recvobj.c)
    retobj.code  = PDEFINE.RET.SUCCESS
    retobj.deskInfo = localGetDeskInfo(uid,recvobj.lat,recvobj.lng)
    return resp(retobj)
end

-- 用户离线获取牌桌信息
function CMD.getDeskInfo(source,msg)
	local recvobj = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	return localGetDeskInfo(uid,recvobj.lat,recvobj.lng)
end

function CMD.notyDeskInfo(uid)
	local muser = seleteUserInfo(uid,"uid")
	local deskInfo = localGetDeskInfo(uid)
	local noty_retobj  = {}
	noty_retobj.code   = PDEFINE.RET.SUCCESS
	noty_retobj.response = {}
	noty_retobj.response.errorCode = PDEFINE.RET.SUCCESS
	noty_retobj.c      = PDEFINE.NOTIFY.NOTY_UPDATE_DESKINFO
	noty_retobj.response.deskInfo = deskInfo
	if muser.cluster_info and muser.ofline == 0 then
	    pcall(cluster.call, muser.cluster_info.server, muser.cluster_info.address, "sendToClient", cjson.encode(noty_retobj))
	end
end

function CMD.getLocatingList(source,msg)
	local recvobj = cjson.decode(msg)
	local retobj = {}
	deskInfo.locatingList = hongzhongtool.jisuanXY(deskInfo.users)
	retobj.c      = math.floor(recvobj.c)
    retobj.code  = PDEFINE.RET.SUCCESS
    retobj.locatingList = deskInfo.locatingList
    return resp(retobj)
end

-- 退出房间
function CMD.exitG(source,msg)
    local recvobj = cjson.decode(msg)
    local uid     = math.floor(recvobj.uid)
    local user  = seleteUserInfo(uid, "uid")
    if user then  --玩家离开 必须存在房间中
        if deskInfo.bigState == 0 then
            for i, user in pairs(deskInfo.users) do
                if user.uid == uid then
                	if usersAutoFuc[user.seat] then 
						usersAutoFuc[user.seat](user.seat)
					end
                    local retobj = {}
                    retobj.c     = PDEFINE.NOTIFY.exit
                    retobj.code  = PDEFINE.RET.SUCCESS
                    retobj.uid   = uid
                    retobj.seat = user.seat
                    --pcall(cluster.call, user.cluster_info.server, user.cluster_info.address, "deskBack", PDEFINE.GAME_TYPE.MJ_HONGZ) --释放桌子对象
                    for _, muser in pairs(deskInfo.users) do
                        if muser.uid ~= uid  and muser.ofline == 0 then
                            pcall(cluster.call, muser.cluster_info.server, muser.cluster_info.address, "sendToClient", cjson.encode(retobj))
                        end
                    end
                    setSeatId(user.seat)
                    pcall(cluster.call, "clubs", ".clubsmgr", "deltelUser", uid, deskInfo.conf.clubid,deskInfo.conf.deskId)
                    pcall(cluster.call, user.cluster_info.server, user.cluster_info.address, "deskBack", PDEFINE.GAME_TYPE.MJ_HONGZ) --释放桌子对象
                    table.remove(deskInfo.users, i)
                    break
                end
            end
        else
            return PDEFINE.RET.ERROR.GAME_ING_ERROR --游戏中不能退出
        end



        if #deskInfo.users == 0 then --需要特殊处理减少桌子跟清空桌子信息
            deskInfo.bigState = 0
            deskInfo.smallState = 0
            deskInfo.conf.curseat = 0
			deskInfo.bankerInfo = {uid = 0, count = 0, seat = 0}
			deskInfo.actionInfo = {iswait = 0, prioritySeat = 0, waitList = {},curaction = {seat = 0, type = 0, time = timeout[1], card = 0},nextaction = {seat = 0, type = 0}}
			local seat = deskInfo.conf.seat
			waitAction = {}
			existSeatIdList = {}
			for i =1, seat do
				table.insert(existSeatIdList,i)
			end
			return PDEFINE.RET.SUCCESS
        end
        notyGpsColour()
    end
    return PDEFINE.RET.SUCCESS
end


--用户在线离线
function CMD.ofline(source,ofline,uid)
	local user = seleteUserInfo(uid,"uid")
	if user then
		local retobj = {}
		user.ofline = ofline
		retobj.c = PDEFINE.NOTIFY.NOTIFY_ONLINE
		retobj.code = PDEFINE.RET.SUCCESS
		retobj.ofline = ofline
		retobj.uid = user.uid
		retobj.seat = user.seat
		broadcastDesk(cjson.encode(retobj))
		pcall(cluster.call, "clubs", ".clubsmgr", "setOnline", user.uid,deskInfo.conf.clubid,ofline)
	end
end

function CMD.sendChatMsg(source,msg)
	local recvobj = cjson.decode(msg)
	local uid   = math.floor(recvobj.uid)
	local chatInfo = recvobj.chatInfo
	local noty_retobj = {}
	noty_retobj.c = PDEFINE.NOTIFY.NOTIFY_CHAT
	noty_retobj.code = PDEFINE.RET.SUCCESS
	noty_retobj.chatInfo = chatInfo
	broadcastDesk(cjson.encode(noty_retobj))
	return PDEFINE.RET.SUCCESS
end

function CMD.gpsUpdate(source,uid,lat,lng)
	local user = seleteUserInfo(uid,"uid")
	if user then
		user.lat = lat
		user.lng = lng
		notyGpsColour()
	end
end

local function addAgreeDissolveUsers(uid,value)
	for _,user in pairs(deskInfo.dissolveInfo.agreeUsers) do
		if user.uid == uid then
			user.isargee = value
		end
	end
	local isDisslve = true
	for _,user in pairs(deskInfo.dissolveInfo.agreeUsers) do
		if user.isargee ~= 1 then
			return false
		end
	end
	return isDisslve
end



--发起解散
function CMD.dissolve(source,msg)
	local recvobj = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local user = seleteUserInfo(uid,"uid")
	if deskInfo.conf.isdissolve == 0 then
		return PDEFINE.RET.SUCCESS --不可解散
	end
	if not user then
		return PDEFINE.RET.ERROR.AlREADY_BACK --用户已退出
	end
	if deskInfo.dissolveInfo.iStart == 1 then
		return PDEFINE.RET.ERROR.ACTION_ERROR --发起过解散
	end
	if deskInfo.bigState == 1 then
		deskInfo.dissolveInfo.iStart = 1
		deskInfo.dissolveInfo.startUid = user.uid
		deskInfo.dissolveInfo.startPlayername = user.playername
		deskAutoFuc = user_set_timeout(deskInfo.dissolveInfo.time*100,autoDissolve,1)
		deskInfo.dissolveInfo.distimeoutBeginTime  = os.time() --倒计时开始时间
		deskInfo.dissolveInfo.distimeoutIntervel   = deskInfo.dissolveInfo.time
		addAgreeDissolveUsers(uid,1)
		local retobj    = {}
	    retobj.c        = PDEFINE.NOTIFY.senddissolve
	    retobj.code     = PDEFINE.RET.SUCCESS
	    retobj.uid      = uid
	    retobj.dissolveInfo    = deskInfo.dissolveInfo
	    broadcastDesk(cjson.encode(retobj))
	elseif deskInfo.bigState == 0 then
		local retobj    = {}
		retobj.c        = PDEFINE.NOTIFY.succeddissolve
		retobj.code     = PDEFINE.RET.SUCCESS
		retobj.isShowJieSuan = 1
		broadcastDesk(cjson.encode(retobj))
		big_over()
	end
	return PDEFINE.RET.SUCCESS
end

--同意解散
function CMD.agreeDissolve(source,msg)
	local recvobj = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local user = seleteUserInfo(uid,"uid")
	if not user then
		return PDEFINE.RET.ERROR.AlREADY_BACK --用户已退出
	end
	if deskInfo.bigState == 1 and deskInfo.dissolveInfo.iStart == 1 then
		local isDissolve = addAgreeDissolveUsers(uid,1)
		local retobj    = {}
	    retobj.c        = PDEFINE.NOTIFY.agreedissolve
	    retobj.code     = PDEFINE.RET.SUCCESS
	    retobj.uid      = uid
	    retobj.playername    = user.playername
	    retobj.dissolveInfo = deskInfo.dissolveInfo
	    broadcastDesk(cjson.encode(retobj))

	    if isDissolve then
	    	if deskAutoFuc then deskAutoFuc() end
	    	local retobj    = {}
		    retobj.c        = PDEFINE.NOTIFY.succeddissolve
		    retobj.code     = PDEFINE.RET.SUCCESS
		    retobj.isShowJieSuan = 1
		    broadcastDesk(cjson.encode(retobj))

		    local huPaiInfo = {}
			huPaiInfo.hseat = deskInfo.actionInfo.curaction.seat
			huPaiInfo.hcard = deskInfo.actionInfo.curaction.card
			huPaiInfo.htype = hongzhongtool.HUPAI_TYPE.liuju
			huPaiInfo.isdissolve = true
			hupaiBance(huPaiInfo)
	    end
	end
	return PDEFINE.RET.SUCCESS
end

--拒绝解散
function CMD.refuseDissolve(source,msg)
	local recvobj = cjson.decode(msg)
	local uid = math.floor(recvobj.uid)
	local user = seleteUserInfo(uid,"uid")
	if not user then
		return PDEFINE.RET.ERROR.AlREADY_BACK --用户已退出
	end
		
	if deskInfo.bigState == 1 and deskInfo.dissolveInfo.iStart == 1 then
		initDissolveInfo()
		local retobj    = {}
	    retobj.c        = PDEFINE.NOTIFY.refusedissolve
	    retobj.code     = PDEFINE.RET.SUCCESS
	    retobj.uid      = uid
	    retobj.playername    = user.playername
	    if deskAutoFuc then deskAutoFuc() end
	    broadcastDesk(cjson.encode(retobj))
	end
	return PDEFINE.RET.SUCCESS
end


skynet.start(function()
	skynet.dispatch("lua", function(session, source, command, ...)
		local f = assert(CMD[command])
		skynet.retpack(f(source, ...))
	end)

	collectgarbage("collect")
end)

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title 🧨 砲轟年獸 (V5 - 最終完整版)
 * @dev 
 * 1. 資金分配 (攻擊時): 80% 進獎池，20% 進分紅 (其中 Owner 拿走分紅的 1% 作為管理費)。
 * 2. 獎金分配 (結算時): 80% 給贏家，20% 留做下一輪底池。
 * 3. 自動化: 內建 12 年初五開工時間表，結算後自動進入下一年。
 * 4. 安全性: 內建 Owner 手動熔斷機制 (Fuse)，僅回收獎池，不動用玩家分紅。
 */
contract NianBeast {
    
    // ==========================================
    //      1. 設定與變數 (State Variables)
    // ==========================================

    // 存儲歷年「初五開工日 12:00:00 (GMT+8)」的時間戳
    uint256[] public hardDeadlines;
    
    // 目前進行到第幾年 (陣列索引 0=2025, 1=2026...)
    uint256 public currentYearIndex; 

    // 當前年度的強制結束時間 (硬死線)
    uint256 public hardDeadline; 
    
    address public owner;           // 合約擁有者
    address public lastAttacker;    // 最後一位攻擊者 (潛在贏家)
    
    uint256 public deadline;        // 軟性倒數時間 (每次攻擊會重置)
    uint256 public nianHp;          // 🔴 年獸血量 (即大獎池)，歸屬於贏家與下一輪底池
    uint256 public totalShares;     // 全網總股份 (玩家投入金額總和)
    bool public isGameOver;         // 遊戲是否已結束/暫停

    // 🆕 Owner 累積待領的管理費 (攻擊金額的 0.2%)
    uint256 public pendingOwnerFee; 

    // 分紅系統核心變數 (每股累積可領分紅)
    uint256 public accDividendPerShare; 
    uint256 public constant MAGNITUDE = 1e12; // 精度放大倍數，防止除法小數點誤差

    // 玩家資料結構
    struct Player {
        uint256 shares;         // 玩家持有的股份 (投入金額)
        uint256 rewardDebt;     // 已結算的債務 (用於計算當前可領)
        uint256 pendingReward;  // 待領取的累積獎勵
    }

    mapping(address => Player) public players;

    // ==========================================
    //      2. 事件 (Events) - 用於前端監聽
    // ==========================================
    event Attacked(address indexed player, uint256 amount, uint256 newDeadline); // 攻擊發生
    event GameEnded(address indexed winner, uint256 winAmount, uint256 nextReserve); // 遊戲結算
    event GameRestarted(uint256 newYearIndex, uint256 newHardDeadline); // 新的一年開始
    event DividendClaimed(address indexed player, uint256 amount); // 玩家領取分紅
    event OwnerFeeClaimed(uint256 amount); // Owner 領取管理費
    event ReceivedFunds(address indexed sender, uint256 amount); // 收到外部資金(如擲筊)
    event DeadlinesExtended(uint256 count); // 時間表擴充
    event FuseTriggered(uint256 ownerAmount); // 保險絲熔斷

    // ==========================================
    //      3. 初始化 (Constructor)
    // ==========================================
    constructor() {
        owner = msg.sender;
        
        // 🗓️ 寫入 2025 ~ 2036 的農曆初五 12:00 (GMT+8) 時間戳
        hardDeadlines.push(1738468800); // 2025-02-02 (蛇)
        hardDeadlines.push(1771646400); // 2026-02-21 (馬)
        hardDeadlines.push(1802232000); // 2027-02-10 (羊)
        hardDeadlines.push(1832817600); // 2028-01-30 (猴)
        hardDeadlines.push(1865995200); // 2029-02-17 (雞)
        hardDeadlines.push(1896580800); // 2030-02-07 (狗)
        hardDeadlines.push(1927252800); // 2031-01-27 (豬)
        hardDeadlines.push(1960430400); // 2032-02-15 (鼠)
        hardDeadlines.push(1991016000); // 2033-02-04 (牛)
        hardDeadlines.push(2024280000); // 2034-02-23 (虎)
        hardDeadlines.push(2054865600); // 2035-02-12 (兔)
        hardDeadlines.push(2085451200); // 2036-02-01 (龍)

        currentYearIndex = 0;
        hardDeadline = hardDeadlines[0]; 
        
        // 初始軟倒數設為 24 小時後，給予第一天緩衝期
        deadline = block.timestamp + 24 hours; 
    }

    // 接收外部資金 (如擲筊遊戲的 10%)
    // 這部分資金 100% 進入年獸血量 (nianHp)，不參與分紅分配
    receive() external payable {
        nianHp += msg.value;
        emit ReceivedFunds(msg.sender, msg.value);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // ==========================================
    //      4. 核心玩法：攻擊 (Attack)
    // ==========================================
    function attack() external payable {
        // 檢查：遊戲是否被鎖定、是否超過硬死線、是否超過軟倒數
        require(!isGameOver, "Game locked");
        require(block.timestamp < hardDeadline, "Hard deadline passed");
        require(block.timestamp < deadline, "Time up");

        uint256 amount = msg.value;
        uint256 newDuration;

        // 設定不同金額對應的冷卻時間
        if (amount == 0.001 ether) { newDuration = 1 hours; } 
        else if (amount == 0.01 ether) { newDuration = 30 minutes; } 
        else if (amount == 0.1 ether) { newDuration = 15 minutes; } 
        else if (amount == 1 ether) { newDuration = 5 minutes; } 
        else { revert("Invalid amount"); }

        // 更新軟倒數時間
        deadline = block.timestamp + newDuration;
        // 如果軟倒數超過了硬死線，強制截斷
        if (deadline > hardDeadline) {
            deadline = hardDeadline;
        }

        lastAttacker = msg.sender;

        // 💰 --- 資金分配邏輯 --- 💰
        
        // 1. 計算分紅總額 (攻擊金的 20%)
        uint256 totalDividendPart = (amount * 20) / 100;
        
        // 2. 計算進入年獸獎池金額 (攻擊金的 80%)
        uint256 poolPart = amount - totalDividendPart;
        
        // 3. 拆解分紅細項
        // Owner 拿走分紅部分的 1% (即總金額的 0.2%)
        uint256 ownerDividend = (totalDividendPart * 1) / 100;
        // 玩家們分配剩下的 99% (即總金額的 19.8%)
        uint256 playerDividend = totalDividendPart - ownerDividend;

        // 4. 執行分配
        // 累積 Owner 管理費 (需手動提領)
        pendingOwnerFee += ownerDividend;

        // 加入年獸獎池
        nianHp += poolPart;

        // 分配給全網股東
        if (totalShares > 0) {
            accDividendPerShare += (playerDividend * MAGNITUDE) / totalShares;
        } else {
            // 如果還沒人玩，這部分暫時加回大池
            nianHp += playerDividend;
        }

        // 5. 更新玩家股份狀態 (先結算舊分紅，再增加新股份)
        Player storage p = players[msg.sender];
        if (p.shares > 0) {
            uint256 pending = (p.shares * accDividendPerShare / MAGNITUDE) - p.rewardDebt;
            p.pendingReward += pending;
        }

        p.shares += amount;
        totalShares += amount;
        p.rewardDebt = p.shares * accDividendPerShare / MAGNITUDE;

        emit Attacked(msg.sender, amount, deadline);
    }

    // ==========================================
    //      5. 結算 (Settle) - 正常遊戲流程
    // ==========================================
    function settleGame() external {
        require(!isGameOver, "Already settled");
        // 條件：必須超時 (軟性倒數結束 OR 硬性時間到)
        require(block.timestamp >= deadline || block.timestamp >= hardDeadline, "Running");

        uint256 jackpot = nianHp;
        uint256 winnerShare = 0;
        uint256 nextRoundReserve = 0; 

        if (lastAttacker != address(0)) {
            // 🏆 贏家拿 80%
            winnerShare = (jackpot * 80) / 100;
            // 🔄 20% 留給下一輪
            nextRoundReserve = jackpot - winnerShare;

            (bool success, ) = lastAttacker.call{value: winnerShare}("");
            require(success, "Tx fail");
        } else {
            // 如果這一年都沒人玩，全部留到下一輪
            nextRoundReserve = jackpot;
        }

        emit GameEnded(lastAttacker, winnerShare, nextRoundReserve);

        // --- 自動重啟下一輪 ---
        nianHp = nextRoundReserve; // 設定新底池
        lastAttacker = address(0); // 清空贏家
        currentYearIndex++;        // 推進年份
        
        // 檢查是否還有未來時間表
        if (currentYearIndex < hardDeadlines.length) {
            hardDeadline = hardDeadlines[currentYearIndex]; 
            deadline = block.timestamp + 24 hours; 
            emit GameRestarted(currentYearIndex, hardDeadline);
        } else {
            // 如果12年時間用完，暫停遊戲，等待 Owner 加時間
            isGameOver = true; 
        }
    }

    // ==========================================
    //      6. 保險絲熔斷 (Circuit Breaker)
    // ==========================================
    /**
     * @dev 緊急終止遊戲。只有 Owner 可以呼叫。
     * 用途：當遊戲發生不可預期停滯，或者 Owner 決定永久停止運營時使用。
     * 安全性：只會提領 nianHp (獎池)，絕對不會動到玩家已累積但未提領的分紅。
     */
    function triggerFuse() external onlyOwner {
        // 條件：必須是時間已結束但尚未結算的狀態
        require(block.timestamp >= deadline || block.timestamp >= hardDeadline, "Game running");
        require(!isGameOver, "Already over");

        uint256 jackpot = nianHp;
        uint256 winnerShare = 0;
        uint256 ownerShare = 0;

        // 1. 依然發放贏家獎金 (80%)，保持信譽
        if (lastAttacker != address(0)) {
            winnerShare = (jackpot * 80) / 100;
            (bool success, ) = lastAttacker.call{value: winnerShare}("");
            require(success, "Winner pay failed");
        }

        // 2. 剩餘資金 (20%) 歸還 Owner
        ownerShare = jackpot - winnerShare;
        
        // 3. 永久鎖定遊戲
        isGameOver = true; 
        nianHp = 0;        

        // 4. 提款給 Owner
        if (ownerShare > 0) {
            (bool successOwner, ) = owner.call{value: ownerShare}("");
            require(successOwner, "Owner pay failed");
        }

        emit GameEnded(lastAttacker, winnerShare, 0);
        emit FuseTriggered(ownerShare);
    }

    // ==========================================
    //      7. 領取與查詢功能
    // ==========================================
    
    // ✅ 玩家領取分紅 (Owner 呼叫此函數時，會一併領取管理費)
    function claimDividend() external {
        Player storage p = players[msg.sender];
        
        // 計算玩家分紅
        uint256 pending = 0;
        if (p.shares > 0) {
            pending = (p.shares * accDividendPerShare / MAGNITUDE) - p.rewardDebt;
        }
        uint256 totalToSend = p.pendingReward + pending;

        // 重置狀態
        p.pendingReward = 0;
        if (p.shares > 0) {
            p.rewardDebt = p.shares * accDividendPerShare / MAGNITUDE;
        }

        // 🆕 如果是 Owner，額外加上累積的管理費
        if (msg.sender == owner && pendingOwnerFee > 0) {
            uint256 fee = pendingOwnerFee;
            pendingOwnerFee = 0;
            totalToSend += fee;
            emit OwnerFeeClaimed(fee);
        }

        require(totalToSend > 0, "No dividends or fees to claim");

        (bool success, ) = msg.sender.call{value: totalToSend}("");
        require(success, "Transfer failed");

        if (totalToSend > 0) {
            emit DividendClaimed(msg.sender, totalToSend); 
        }
    }

    // 擴充時間表 (12年後用)
    function addFutureDeadlines(uint256[] calldata _newDeadlines) external onlyOwner {
        for(uint256 i = 0; i < _newDeadlines.length; i++) {
            hardDeadlines.push(_newDeadlines[i]);
        }
        // 如果遊戲之前因為時間用完而暫停，現在自動重啟
        if (isGameOver && currentYearIndex < hardDeadlines.length) {
            hardDeadline = hardDeadlines[currentYearIndex];
            deadline = block.timestamp + 24 hours;
            isGameOver = false; 
            emit GameRestarted(currentYearIndex, hardDeadline);
        }
        emit DeadlinesExtended(_newDeadlines.length);
    }

    // 前端查詢用：顯示待領金額 (Owner 會看到 分紅+管理費)
    function getPendingDividend(address _user) external view returns (uint256) {
        Player storage p = players[_user];
        uint256 pending = 0;
        if (p.shares > 0) {
            pending = (p.shares * accDividendPerShare / MAGNITUDE) - p.rewardDebt;
        }
        uint256 total = p.pendingReward + pending;

        if (_user == owner) {
            total += pendingOwnerFee;
        }

        return total;
    }
    
    // 前端查詢用：剩餘時間 (回傳秒數)
    function getTimeLeft() external view returns (uint256) {
        if (isGameOver) return 0;
        if (block.timestamp >= hardDeadline) return 0; 
        if (block.timestamp >= deadline) return 0;     
        
        uint256 softRem = deadline - block.timestamp;
        uint256 hardRem = hardDeadline - block.timestamp;
        
        // 回傳兩者中較短的那個
        return softRem < hardRem ? softRem : hardRem;
    }
}
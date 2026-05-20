// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../../BaseForkFixture.sol";

/// @notice Fork test that verifies deploying a new Redistributor with dual gauge factory support,
///         migrating permissions from the old redistributor, and redistributing to gauges from all factory types.
contract RedistributorMigrationForkTest is BaseForkFixture {
    using stdStorage for StdStorage;

    CLPool public pool;
    CLPool public pool2;
    CLGauge public gauge;
    CLGauge public gauge2;

    // The new redistributor that supports both gauge factories
    Redistributor public newRedistributor;

    // legacyGaugeFactory2 = the 2nd CL gauge factory (had the old redistributor, capped)
    CLGaugeFactory public legacyGaugeFactory2;

    // Live gauges from different factories
    address public legacyCLGauge; // from legacyGaugeFactory (original, uncapped)
    address public legacy2CLGauge; // from legacyGaugeFactory2 (capped)
    address public v2Gauge; // V2 gauge (not CL, uncapped)

    uint256 public epochStart;
    uint256 public totalEmissions;

    function setUp() public virtual override {
        blockNumber = 44384394;
        super.setUp();

        // Create pools and gauges from the new factory
        pool = CLPool(
            poolFactory.createPool({
                tokenA: address(token0),
                tokenB: address(token1),
                tickSpacing: TICK_SPACING_60,
                sqrtPriceX96: encodePriceSqrt(1, 1)
            })
        );
        pool2 = CLPool(
            poolFactory.createPool({
                tokenA: address(token0),
                tokenB: address(token1),
                tickSpacing: TICK_SPACING_200,
                sqrtPriceX96: encodePriceSqrt(1, 1)
            })
        );

        vm.startPrank(voter.governor());
        gauge = CLGauge(payable(voter.createGauge({_poolFactory: address(poolFactory), _pool: address(pool)})));
        gauge2 = CLGauge(payable(voter.createGauge({_poolFactory: address(poolFactory), _pool: address(pool2)})));
        vm.stopPrank();

        legacyGaugeFactory2 = CLGaugeFactory(0xB630227a79707D517320b6c0f885806389dFcbB3);

        legacyCLGauge = 0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8; // WETH/USDC gauge (original legacy factory)
        legacy2CLGauge = 0x78329E80c7999548c81C5ab93185cf1316747845; // gauge from legacyGaugeFactory2
        v2Gauge = 0x4F09bAb2f0E15e2A078A227FE1537665F55b8360; // USDC/AERO V2 gauge

        // Deploy the new redistributor with dual factory support:
        //   gaugeFactory = current (new) gauge factory (from BaseFixture)
        //   legacyGaugeFactory = legacyGaugeFactory2 (the 2nd factory, capped)
        newRedistributor = new Redistributor({
            _voter: address(voter),
            _gaugeFactory: address(gaugeFactory),
            _legacyGaugeFactory: address(legacyGaugeFactory2),
            _upkeepManager: address(upkeepManager),
            _initialOwner: users.owner
        });

        MockUpkeepManager(address(upkeepManager)).setUpkeep({_upkeep: users.alice, _state: true});

        skipToNextEpoch(0);
        epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
    }

    // ─── Helpers ───

    function _migrateToNewRedistributor() internal {
        // Step 1: Transfer permissions (escrow.team + legacyGaugeFactory.notifyAdmin) to new redistributor
        vm.prank(users.owner);
        redistributor.transferPermissions({_newRedistributor: address(newRedistributor)});

        // Step 2: Set new redistributor on the current gauge factory
        vm.prank(users.owner);
        gaugeFactory.setRedistributor({_redistributor: address(newRedistributor)});

        address _admin = legacyGaugeFactory2.emissionAdmin();
        vm.prank(_admin);
        legacyGaugeFactory2.setRedistributor({_redistributor: address(newRedistributor)});
    }

    function _seedAndVote() internal {
        deal(address(rewardToken), address(newRedistributor), 0);

        skipToNextEpoch(1 hours + 1);

        // Alice creates veNFT and votes for our pool
        deal(address(rewardToken), users.alice, TOKEN_1 * 1_000);
        vm.startPrank(users.alice);
        rewardToken.approve(address(escrow), TOKEN_1 * 1_000);
        uint256 tokenIdAlice = escrow.createLock(TOKEN_1 * 1_000, 365 days * 4);

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256[] memory votes = new uint256[](1);
        votes[0] = 100;
        voter.vote(tokenIdAlice, pools, votes);
        vm.stopPrank();

        // Skip to next epoch and deposit rewards into new redistributor
        skipToNextEpoch(0);
        epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);

        totalEmissions = TOKEN_1 * 10_000;
        deal(address(rewardToken), address(gauge2), totalEmissions);
        vm.startPrank(address(gauge2));
        rewardToken.approve(address(newRedistributor), totalEmissions);
        newRedistributor.deposit({_amount: totalEmissions});
        vm.stopPrank();

        skip(10 minutes);
    }

    // ─── Tests ───

    function test_NewRedistributorInitialState() public view {
        assertEq(newRedistributor.gaugeFactory(), address(gaugeFactory));
        assertEq(newRedistributor.legacyGaugeFactory(), address(legacyGaugeFactory2));
        assertEq(address(newRedistributor.voter()), address(voter));
        assertEq(newRedistributor.minter(), address(minter));
        assertEq(newRedistributor.escrow(), address(escrow));
        assertEq(newRedistributor.rewardToken(), address(rewardToken));
        assertEq(newRedistributor.owner(), users.owner);
    }

    function test_MigratePermissions() public {
        // Before: old redistributor holds permissions
        assertEq(escrow.team(), address(redistributor));
        assertEq(legacyGaugeFactory.notifyAdmin(), address(redistributor));

        _migrateToNewRedistributor();

        // After: new redistributor holds permissions
        assertEq(escrow.team(), address(newRedistributor));
        assertEq(legacyGaugeFactory.notifyAdmin(), address(newRedistributor));
        assertEq(gaugeFactory.redistributor(), address(newRedistributor));

        assertEq(legacyGaugeFactory2.redistributor(), address(newRedistributor));
    }

    function test_RedistributeToCurrentFactoryGauge() public {
        _migrateToNewRedistributor();
        _seedAndVote();

        // gauge is from the current (new) gauge factory — should have cap enforcement
        assertTrue(gaugeFactory.isGauge(address(gauge)));

        uint256 gaugeBefore = rewardToken.balanceOf(address(gauge));
        uint256 minterBefore = rewardToken.balanceOf(address(minter));
        uint256 redistributorBefore = rewardToken.balanceOf(address(newRedistributor));

        address[] memory gauges = new address[](1);
        gauges[0] = address(gauge);

        vm.prank(users.alice);
        newRedistributor.redistribute({_gauges: gauges});

        uint256 redistributorAfter = rewardToken.balanceOf(address(newRedistributor));

        // Redistributor balance should have decreased
        assertLt(redistributorAfter, redistributorBefore);

        // Emissions went to gauge or minter (cap enforcement may redirect to minter)
        uint256 gaugeReceived = rewardToken.balanceOf(address(gauge)) - gaugeBefore;
        uint256 minterReceived = rewardToken.balanceOf(address(minter)) - minterBefore;
        assertGt(gaugeReceived + minterReceived, 0);

        assertTrue(newRedistributor.isRedistributed(epochStart, address(gauge)));
    }

    function test_RedistributeToLegacy2FactoryGauge() public {
        _migrateToNewRedistributor();
        _seedAndVote();

        // legacy2 gauge is in legacyGaugeFactory2 — should have cap enforcement
        assertTrue(legacyGaugeFactory2.isGauge(legacy2CLGauge));
        assertFalse(gaugeFactory.isGauge(legacy2CLGauge));

        uint256 gaugeBefore = rewardToken.balanceOf(legacy2CLGauge);
        uint256 minterBefore = rewardToken.balanceOf(address(minter));

        address[] memory gauges = new address[](1);
        gauges[0] = legacy2CLGauge;

        vm.prank(users.alice);
        newRedistributor.redistribute({_gauges: gauges});

        uint256 gaugeReceived = rewardToken.balanceOf(legacy2CLGauge) - gaugeBefore;
        uint256 minterReceived = rewardToken.balanceOf(address(minter)) - minterBefore;
        assertGt(gaugeReceived + minterReceived, 0);
        assertTrue(newRedistributor.isRedistributed(epochStart, legacy2CLGauge));
    }

    function test_RedistributeToOriginalLegacyFactoryGauge() public {
        _migrateToNewRedistributor();
        _seedAndVote();

        // Original legacy gauge is NOT in either capped factory — no cap enforcement
        assertFalse(gaugeFactory.isGauge(legacyCLGauge));
        assertFalse(legacyGaugeFactory2.isGauge(legacyCLGauge));

        uint256 gaugeBefore = rewardToken.balanceOf(legacyCLGauge);

        address[] memory gauges = new address[](1);
        gauges[0] = legacyCLGauge;

        vm.prank(users.alice);
        newRedistributor.redistribute({_gauges: gauges});

        assertGt(rewardToken.balanceOf(legacyCLGauge), gaugeBefore);
        assertTrue(newRedistributor.isRedistributed(epochStart, legacyCLGauge));
    }

    function test_RedistributeToV2Gauge() public {
        _migrateToNewRedistributor();
        _seedAndVote();

        // V2 gauge is not in either CL gauge factory — should skip cap logic entirely
        assertFalse(gaugeFactory.isGauge(v2Gauge));

        uint256 gaugeBefore = rewardToken.balanceOf(v2Gauge);

        address[] memory gauges = new address[](1);
        gauges[0] = v2Gauge;

        vm.prank(users.alice);
        newRedistributor.redistribute({_gauges: gauges});

        assertGt(rewardToken.balanceOf(v2Gauge), gaugeBefore);
        assertTrue(newRedistributor.isRedistributed(epochStart, v2Gauge));
    }

    function test_DepositFromCurrentFactoryGauge() public {
        _migrateToNewRedistributor();

        skipToNextEpoch(0);
        epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);

        uint256 depositAmount = TOKEN_1 * 100;
        deal(address(rewardToken), address(gauge), depositAmount);

        vm.startPrank(address(gauge));
        rewardToken.approve(address(newRedistributor), depositAmount);
        newRedistributor.deposit({_amount: depositAmount});
        vm.stopPrank();

        assertTrue(newRedistributor.isExcluded(epochStart, address(gauge)));
        assertEq(rewardToken.balanceOf(address(newRedistributor)), depositAmount);
    }
}

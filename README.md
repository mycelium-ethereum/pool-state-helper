# Pool State Helper

Helpers to get pool state.

### Assumptions & Constraints:

- An upkeep **will** happen every `UpdateInterval`
- May not work if `FrontRunningInterval` is not completely divisible by `UpdateInterval`
- Does not simulate keeper fees that get paid out of the pool
- Does not simulate dynamic minting fees

### Usage:

###### fullCommitPeriod(address leveragedPool)

`leveragedPool` - Leveraged Pool Address

Returns number of periods that will be executed during the `FrontRunningInterval`
<br>

###### getExpectedState(address leveragedPool, uint256 periods)

`leveragedPool` - Leveraged Pool Address
`periods` - Number of commit periods to simulate

Returns the `ExpectedPoolState` after the TotalCommitments for `periods` are applied

```
    struct ExpectedPoolState {
        //in settlementToken decimals
        uint256 cumulativePendingMintSettlement;
        uint256 skew;
        uint256 longSupply;
        uint256 longBalance;
        uint256 longPrice;
        uint256 shortSupply;
        uint256 shortBalance;
        uint256 shortPrice;
    }
```

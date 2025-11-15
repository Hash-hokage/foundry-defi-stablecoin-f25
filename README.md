# **Decentralized Stablecoin (DSC)**

A decentralized, overcollateralized, crypto-backed stablecoin system built with **Foundry**.
DSC targets a soft peg of **1 DSC = $1 USD**, backed by exogenous collateral (WETH, WBTC).

Unlike MakerDAO’s DAI, DSC removes governance and fees, focusing on a minimal, algorithmic design governed only by smart contract logic.

---

## **Features**

* Overcollateralized stablecoin backed by ETH/BTC-based assets
* Algorithmic stability with no interest rates or governance
* Health-factor based solvency checks
* Liquidation incentives with bonus rewards
* Chainlink oracle integration with stale price protection
* Comprehensive Foundry tests (unit, fuzz, invariants)

---

# **Core Concepts**

## **1. Overcollateralization**

Users must deposit collateral (WETH, WBTC) before minting DSC.
Collateral value must always exceed minted DSC value.

---

## **2. Health Factor**

The protocol measures user safety via a **Health Factor (HF)**.

* **Liquidation Threshold:** 50%
  Only half of collateral value is considered when checking minting safety.

* **Minimum Health Factor:** 1 (scaled as 1e18)

### **Formula**

```
Health Factor =
(Total Collateral USD Value * LIQUIDATION_THRESHOLD / 100)
---------------------------------------------------------
              Total DSC Minted in USD
```

Any action that drops HF below **1** reverts with
`DSCEngine__BreakHealthFactor`.

---

## **3. Minting & Burning**

### **Minting**

Users can mint DSC via:

* `depositCollateralAndMintDsc()`
* `depositCollateral()`
* `mintDsc()`

Safety enforced via Health Factor.

### **Burning**

Users burn DSC to repay debt.
Only DSCEngine may:

* mint DSC
* burn DSC

Ownership of the DSC token is transferred to DSCEngine upon deployment.

---

## **4. Liquidations**

If a user’s Health Factor falls **below 1**, their position becomes liquidatable.

Liquidators:

1. Repay (burn) DSC on behalf of the unhealthy user
2. Receive their collateral
3. Earn a **10% liquidation bonus**

This ensures liquidation remains profitable during volatility.

---

## **5. Oracle Security**

The system uses **Chainlink AggregatorV3Interface** for pricing (WETH/USD, WBTC/USD).

`OracleLib` ensures:

* prices are fresh
* price feeds older than **3 hours** cause the protocol to revert

This acts as a freeze mechanism to prevent bad pricing events.

---

# **Contract Overview**

## **src/**

### **DecentralizedStableCoin.sol**

* ERC20 token for the stablecoin
* Inherits:

  * `ERC20Burnable`
  * `Ownable`
* Only DSCEngine can mint/burn

---

### **DSCEngine.sol**

Core protocol contract handling:

* Collateral deposits
* Minting & burning DSC
* Redemptions
* Liquidations
* User data tracking
* Price conversions

Key functions include:

* `depositCollateralAndMintDsc`
* `redeemCollateralForDsc`
* `liquidate`
* `getUsdValue`
* `getAccountInformation`

---

### **libraries/OracleLib.sol**

Ensures price feeds are not stale.
Reverts if data exceeds the defined timeout window.

---

# **🛠 Scripts (script/)**

### **DeployDSC.s.sol**

Deploys:

* HelperConfig
* DecentralizedStableCoin
* DSCEngine

Configures feeds, tokens, and transfers token ownership to the engine.

### **HelperConfig.s.sol**

Provides chain-specific configuration.

Supports:

* **Sepolia testnet** (real Chainlink feeds)
* **Local Anvil** (mock tokens + mock feeds)

---

# **Tests (test/)**

### **unit/DSCEngineTest.t.sol**

Covers:

* Input validation
* Mint/redeem rules
* Health factor logic
* Liquidation behavior

### **fuzz/Handler.t.sol**

State-machine fuzzing:

* random deposits
* random minting
* random redemptions

### **fuzz/InvariantsTest.t.sol**

Ensures core safety invariant:

```
Total collateral USD value >= Total DSC supply
```

Guarantees the protocol is always overcollateralized.

---

# **Getting Started**

## **Prerequisites**

* Foundry installed
* Git
* RPC URL (if deploying to testnet)
* Private key (for deployment)

---

## **Installation**

```bash
git clone <YOUR_REPO_URL>
cd <YOUR_REPO_NAME>
git submodule update --init --recursive
forge install
```

---

## **Build**

```bash
forge build
```

---

## **Run Tests**

### All tests

```bash
forge test -vvv
```

### Invariant tests

```bash
forge test --profile invariants
```

### Format check

```bash
forge fmt --check
```

---

# **Deployment**

## **Sepolia Testnet**

Set environment variables:

```bash
export SEPOLIA_RPC_URL=<your_rpc_url>
export PRIVATE_KEY=<your_private_key>
```

Deploy:

```bash
forge script script/DeployDSC.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

---

## **Local Anvil**

```bash
forge script script/DeployDSC.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

HelperConfig deploys the required mocks automatically.

---

## 📦 Dependencies

- **Foundry** — https://github.com/foundry-rs/foundry  
- **forge-std** — https://github.com/foundry-rs/forge-std  
- **OpenZeppelin Contracts** — https://github.com/OpenZeppelin/openzeppelin-contracts  
- **Chainlink Brownie Contracts** — https://github.com/smartcontractkit/chainlink-brownie-contracts

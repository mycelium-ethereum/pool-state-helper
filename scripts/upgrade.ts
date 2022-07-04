// @ts-ignore
import { ethers, network, upgrades } from "hardhat";

const networkToPoolSwapLibraryAddresses: Record<number, string> = {
  42161: "0x71dBdA135d5A9F64306fd22e00E59a5fEdFB86F9", // abitrum one
  421611: "0xCB27C3813D75918f8B764143Cf3717955A5D43b8", // abitrum rinkeby
};

async function main() {
  console.log("IN UPGRADE SCRIPT", network.config.chainId);

  const chainId = network.config.chainId;

  if (!chainId) {
    throw new Error(`No chainId configured for network ${network.name}`);
  }

  const poolSwapLibraryAddress = networkToPoolSwapLibraryAddresses[chainId];

  if (!poolSwapLibraryAddress) {
    throw new Error(`No known pool swap library for chainId ${chainId}`);
  }

  // @ts-ignore: Upgraded contract placeholder
  const PoolStateHelper2 = await ethers.getContractFactory(
    `<UPGRADED_CONTRACT>`,
    {
      libraries: {
        PoolSwapLibrary: poolSwapLibraryAddress,
      },
    }
  );

  // @ts-ignore: Upgraded contract placeholder
  const contract = await upgrades.upgradeProxy(
    `<PROXY_INSTANCE_ADDRESS>`,
    PoolStateHelper2,
    {
      kind: "uups",
      unsafeAllowLinkedLibraries: true,
    }
  );

  // The address the Contract WILL have once mined
  console.log(`Deployed to:`, contract.address);

  // The contract is NOT deployed yet; we must wait until it is mined
  await contract.deployed();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

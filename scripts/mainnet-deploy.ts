import { ethers } from "hardhat";

async function main() {
  const f = await ethers.getContractFactory(`PoolStateHelper`, {
    libraries: {
      PoolSwapLibrary: "0x71dBdA135d5A9F64306fd22e00E59a5fEdFB86F9",
    },
  });

  // If we had constructor arguments, they would be passed into deploy()
  const contract = await f.deploy();

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

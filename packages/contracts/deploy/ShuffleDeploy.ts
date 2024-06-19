const { ethers } = require("hardhat");
const {deploy_shuffle_manager} = require("../helper/deploy")
import { Hilo, Hilo__factory, ShuffleManager } from "../types";
require("dotenv").config();
 
async function main() {
    const [deployer] = await ethers.getSigners();
    let privateKey = process.env.GOERLI_PRIVATE_KEY;
    const sm_owner = deployer;
    const hilo_owner = deployer;
    // deploy shuffleManager
    const SM: ShuffleManager = await deploy_shuffle_manager(sm_owner);
    // deploy gameContract
    let numCard = 52;
    const game: Hilo = await new Hilo__factory(hilo_owner).deploy(SM.address, numCard);
    console.log("gameHilo contract address is:",game.address);
}
 
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
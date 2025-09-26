// Import and register all Hardhat tasks from modular task files
module.exports = function () {
  require("./protocol-improvements")();
  require("./deployment")();
  require("./operations")();
  require("./liquidity")();
  require("./tokens")();
  require("./farming")();
  require("./utilities")();
  require("./verification")();
  require("./abi-generation")();
  require("./tractor")();
};

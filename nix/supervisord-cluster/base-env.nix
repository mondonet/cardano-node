{
  defaultLogConfig
, stateDir
}:

rec {
  useByronWallet = true;
  relaysNew = "127.0.0.1";
  edgePort = 3001;
  confKey = "local";
  private = false;
  networkConfig = {
    GenesisFile = "keys/genesis.json";
    Protocol = "TPraos";
    RequiresNetworkMagic = "RequiresMagic";
    LastKnownBlockVersion-Major = 0;
    LastKnownBlockVersion-Minor = 0;
    LastKnownBlockVersion-Alt = 0;
  };
  nodeConfig = networkConfig // defaultLogConfig;
  consensusProtocol = networkConfig.Protocol;
}

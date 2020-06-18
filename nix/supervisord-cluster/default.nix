{
  pkgs
, lib
, cardano-cli
, numBft ? 1
, numPools ? 2
, d ? "0.5"
, basePort ? 30000
, stateDir ? "./state-cluster"
, initialFunds ? import ./initial-funds.nix
}:
let
  baseEnvConfig = pkgs.callPackage ./base-env.nix { inherit (pkgs.commonLib.cardanoLib) defaultLogConfig; inherit stateDir; };
  mkStartScript = envConfig: let
    systemdCompat.options = {
      systemd.services = lib.mkOption {};
      users = lib.mkOption {};
      assertions = lib.mkOption {};
    };
    eval = let
      extra = {
        services.cardano-node = {
          enable = true;
          inherit (envConfig) operationalCertificate kesKey vrfKey topology nodeConfig nodeConfigFile port dbPrefix socketPath;
          inherit stateDir;
        };
      };
    in lib.evalModules {
      prefix = [];
      modules = import ../nixos/module-list.nix ++ [ systemdCompat extra ];
      args = { inherit pkgs; };
    };
  in pkgs.writeScript "cardano-node" ''
    #!${pkgs.stdenv.shell}
    ${eval.config.services.cardano-node.script}
  '';
  topologyFile = __toFile "topology.yaml" (__toJSON {
    Producers = [
      {
        addr = "127.0.0.1";
        port = basePort + 1;
        valency = 1;
      }
      {
        addr = "127.0.0.1";
        port = basePort + 2;
        valency = 1;
      }
      {
        addr = "127.0.0.1";
        port = basePort + 3;
        valency = 1;
      }
    ];
  });
  supervisorConfig = pkgs.writeText "supervisor.conf" (pkgs.commonLib.supervisord.writeSupervisorConfig {
    supervisord = {
      nodaemon = true;
      logfile = "${stateDir}/supervisord.log";
    };
    "program:bft1" = {
      command = let
        envConfig = baseEnvConfig // {
          operationalCertificate = "${stateDir}/keys/node-bft1/op.cert";
          kesKey = "${stateDir}/keys/node-bft1/kes.skey";
          vrfKey = "${stateDir}/keys/node-bft1/vrf.skey";
          topology = topologyFile;
          socketPath = "${stateDir}/bft1.socket";
          dbPrefix = "db-bft1";
          port = basePort + 1;
          nodeConfigFile = "${stateDir}/config.json";
        };
        script = mkStartScript envConfig;
      in "${script}";
      stdout_logfile = "${stateDir}/bft1.stdout";
      stderr_logfile = "${stateDir}/bft1.stderr";
    };
    "program:pool1" = {
      command = let
        envConfig = baseEnvConfig // {
          operationalCertificate = "${stateDir}/keys/node-pool1/op.cert";
          kesKey = "${stateDir}/keys/node-pool1/kes.skey";
          vrfKey = "${stateDir}/keys/node-pool1/vrf.skey";
          topology = topologyFile;
          socketPath = "${stateDir}/pool1.socket";
          dbPrefix = "db-pool1";
          port = basePort + 2;
          nodeConfigFile = "${stateDir}/config.json";
        };
        script = mkStartScript envConfig;
      in "${script}";
      stdout_logfile = "${stateDir}/pool1.stdout";
      stderr_logfile = "${stateDir}/pool1.stderr";
    };
    "program:pool2" = {
      command = let
        envConfig = baseEnvConfig // {
          operationalCertificate = "${stateDir}/keys/node-pool2/op.cert";
          kesKey = "${stateDir}/keys/node-pool2/kes.skey";
          vrfKey = "${stateDir}/keys/node-pool2/vrf.skey";
          topology = topologyFile;
          socketPath = "${stateDir}/pool2.socket";
          dbPrefix = "db-pool2";
          port = basePort + 3;
          nodeConfigFile = "${stateDir}/config.json";
        };
        script = mkStartScript envConfig;
      in "${script}";
      stdout_logfile = "${stateDir}/pool2.stdout";
      stderr_logfile = "${stateDir}/pool2.stderr";
    };
    "program:webserver" = {
      command = "${pkgs.python3}/bin/python -m http.server ${toString basePort}";
      directory = "${stateDir}/webserver";
    };
  });
  path = lib.makeBinPath [ cardano-cli pkgs.jq pkgs.gnused pkgs.coreutils pkgs.bash pkgs.moreutils ];
  genFiles = ''
    PATH=${path}
    rm -rf ${stateDir}
    mkdir -p ${stateDir}/{keys,webserver}
    cp ${__toFile "node.json" (__toJSON baseEnvConfig.nodeConfig)} ${stateDir}/config.json
    cardano-cli shelley genesis create --testnet-magic 42 \
                                       --genesis-dir ${stateDir}/keys \
                                       --gen-genesis-keys ${toString numBft} \
                                       --gen-utxo-keys 1
    jq -r --arg slotLength 0.2 \
          --arg activeSlotsCoeff 0.1 \
          --arg securityParam 10 \
          --arg epochLength 1500 \
          --arg maxLovelaceSupply 45000000000000000 \
          --arg decentralisationParam ${toString d} \
          --arg updateQuorum ${toString numBft} \
          '. + {
            slotLength: $slotLength|tonumber,
            activeSlotsCoeff: $activeSlotsCoeff|tonumber,
            securityParam: $securityParam|tonumber,
            epochLength: $epochLength|tonumber,
            maxLovelaceSupply: $maxLovelaceSupply|tonumber,
            decentralisationParam: $decentralisationParam|tonumber,
            updateQuorum: $updateQuorum|tonumber,
            initialFunds: ${__toJSON initialFunds}
          }' \
    ${stateDir}/keys/genesis.json | sponge ${stateDir}/keys/genesis.json
    for i in {1..${toString numBft}}
    do
      mkdir -p "${stateDir}/keys/node-bft$i"
      ln -s "../delegate-keys/delegate$i.vrf.skey" "${stateDir}/keys/node-bft$i/vrf.skey"
      ln -s "../delegate-keys/delegate$i.vrf.vkey" "${stateDir}/keys/node-bft$i/vrf.vkey"
      cardano-cli shelley node key-gen-KES \
        --verification-key-file "${stateDir}/keys/node-bft$i/kes.vkey" \
        --signing-key-file "${stateDir}/keys/node-bft$i/kes.skey"
      cardano-cli shelley node issue-op-cert \
        --kes-period 0 \
        --cold-signing-key-file "${stateDir}/keys/delegate-keys/delegate$i.skey" \
        --kes-verification-key-file "${stateDir}/keys/node-bft$i/kes.vkey" \
        --operational-certificate-issue-counter-file "${stateDir}/keys/delegate-keys/delegate$i.counter" \
        --out-file "${stateDir}/keys/node-bft$i/op.cert"
      BFT_PORT=$(("${toString basePort}" + $i))
      echo "$BFT_PORT" > "${stateDir}/keys/node-bft$i/port"
    done
    for i in {1..${toString numPools}}
    do
      mkdir -p "${stateDir}/keys/node-pool$i"
      echo "Generating Pool $i Secrets"
      cardano-cli shelley address key-gen \
        --signing-key-file "${stateDir}/keys/node-pool$i/owner-utxo.skey" \
        --verification-key-file "${stateDir}/keys/node-pool$i/owner-utxo.vkey"
      cardano-cli shelley stake-address key-gen \
        --signing-key-file "${stateDir}/keys/node-pool$i/owner-stake.skey" \
        --verification-key-file "${stateDir}/keys/node-pool$i/owner-stake.vkey"
      cardano-cli shelley stake-address key-gen \
        --signing-key-file "${stateDir}/keys/node-pool$i/reward.skey" \
        --verification-key-file "${stateDir}/keys/node-pool$i/reward.vkey"
      cardano-cli shelley node key-gen \
        --cold-verification-key-file "${stateDir}/keys/node-pool$i/cold.vkey" \
        --cold-signing-key-file "${stateDir}/keys/node-pool$i/cold.skey" \
        --operational-certificate-issue-counter-file "${stateDir}/keys/node-pool$i/cold.counter"
      cardano-cli shelley node key-gen-KES \
        --verification-key-file "${stateDir}/keys/node-pool$i/kes.vkey" \
        --signing-key-file "${stateDir}/keys/node-pool$i/kes.skey"
      cardano-cli shelley node key-gen-VRF \
        --verification-key-file "${stateDir}/keys/node-pool$i/vrf.vkey" \
        --signing-key-file "${stateDir}/keys/node-pool$i/vrf.skey"
      cardano-cli shelley node issue-op-cert \
        --kes-period 0 \
        --cold-signing-key-file "${stateDir}/keys/node-pool$i/cold.skey" \
        --kes-verification-key-file "${stateDir}/keys/node-pool$i/kes.vkey" \
        --operational-certificate-issue-counter-file "${stateDir}/keys/node-pool$i/cold.counter" \
        --out-file "${stateDir}/keys/node-pool$i/op.cert"

      echo "Generating Pool $i Metadata"
      jq -n \
         --arg name "CoolPool$i" \
         --arg description "Cool Pool $i" \
         --arg ticker "COOL$i" \
         --arg homepage "http://localhost:${toString basePort}/pool$i.html" \
         '{"name": $name, "description": $description, "ticker": $ticker, "homepage": $homepage}' > "${stateDir}/webserver/pool$i.json"

      METADATA_URL="http://localhost:${toString basePort}/pool$i.json"
      METADATA_HASH=$(cardano-cli shelley stake-pool metadata-hash --pool-metadata-file "${stateDir}/webserver/pool$i.json")
      POOL_IP="127.0.0.1"
      POOL_PORT=$(("${toString basePort}" + "${toString numBft}" + $i))
      echo "$POOL_PORT" > "${stateDir}/keys/node-pool$i/port"
      POOL_PLEDGE=$(( $RANDOM % 1000000000 + 1000000000000))
      echo $POOL_PLEDGE > "${stateDir}/keys/node-pool$i/pledge"
      POOL_MARGIN_NUM=$(( $RANDOM % 10 + 1))

      cardano-cli shelley stake-pool registration-certificate \
        --cold-verification-key-file "${stateDir}/keys/node-pool$i/cold.vkey" \
        --vrf-verification-key-file "${stateDir}/keys/node-pool$i/vrf.vkey" \
        --pool-pledge "$POOL_PLEDGE" \
        --pool-margin "$(jq -n $POOL_MARGIN_NUM/10)" \
        --pool-cost "$(($RANDOM % 100000000))" \
        --pool-reward-account-verification-key-file "${stateDir}/keys/node-pool$i/reward.vkey" \
        --pool-owner-stake-verification-key-file "${stateDir}/keys/node-pool$i/owner-stake.vkey" \
        --metadata-url "$METADATA_URL" \
        --metadata-hash "$METADATA_HASH" \
        --testnet-magic 42 \
        --out-file "${stateDir}/keys/node-pool$i/register.cert"

    done
  '';

  startSupervisord = pkgs.writeScriptBin "start-cluster" ''
    set -euo pipefail
    ${genFiles}
    ${pkgs.python3Packages.supervisor}/bin/supervisord --config ${supervisorConfig}
  '';

in startSupervisord // { inherit baseEnvConfig; }

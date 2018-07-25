{ makeDesktopItem, network }:

let
  suffix = if network != "mainnet" then "-${network}" else "";
  suffixSp = if network != "mainnet" then " ${network}" else "";
  name = "Daedalus${suffix}";
in makeDesktopItem {
    inherit name;
    exec = "daedalus${suffix}";
    icon = "daedalus";
    desktopName = "Daedalus${suffixSp}";
    genericName = "Crypto-Currency Wallet";
    categories = "Application;Network;";
    startupNotify = "true";
  } // {
    path = "share/applications/${name}.desktop";
  }

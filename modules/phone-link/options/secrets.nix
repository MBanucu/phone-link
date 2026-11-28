# Secret options: the SOCKS credentials.  The password itself never enters the
# store; it stays in the root-only environment file named here.
{ lib, ... }:
{
  options.phoneLink = {
    proxyUser = lib.mkOption {
      type = lib.types.str;
      default = "proxy";
      description = "Username for the phone's SOCKS proxy.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos/phone-socks-secrets";
      description = ''
        Environment file providing PHONE_SOCKS_PASS.  Keep it outside the Nix
        store, readable by root only.
      '';
    };
  };
}

{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    duckdb
    pgcli
    postgresql_17
    sqlite
    sqlite-interactive
    sqlfluff
  ];
}

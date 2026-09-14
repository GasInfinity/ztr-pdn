# ztr-pdn

A reimplementation of the 3DS `pdn` sysmodule written in zig, primarily to learn sysmodule lifecycle.

## Building

The only dependency is `zig 0.16.0` (already available in the repo flake if you use nix)

Run `zig build`; it'll download dependencies and build `zitrus` tools first, afterwards rebuilds are instantaneous.

You should see `pdn.cxi` in `zig-out/bin` alongside `pdn.elf`.

## Running (Luma3DS)

Copy `pdn.cxi` to `/luma/sysmodules/0004013000002102.cxi` in your sd card.
  
...
  
Profit?

## Credits

All credits go to `3dbrew` and `GBATEK` as I could not do this without all the available documentation.

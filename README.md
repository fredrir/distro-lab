# Distro Lab




## `src/`

### `distros/`

Sectioned by `<distro-name>-<purpose>/`

- `<distro-name>`
- - Name of distro. e.g `gentoo` or `nixos`

- `<purpose>`
- - `dev` for dev work, usually used in vm's, and for dev needs like compiling builds.
- - `main` mostly for bare metal testing.

#### `distros/<distro-name>-<purpose>/config`

Configuration of the distro. 
- e.g `config/configuration.nix`

#### `distros/<distro-name>-<purpose>/tofu`

Open tofu 


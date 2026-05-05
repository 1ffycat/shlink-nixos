{ lib
, fetchFromGitHub
, php84
}:

let
  # The PHP interpreter used at build time (for composer install).
  # The NixOS module constructs its own phpWithExts for runtime with the
  # correct pdo_* driver extension; this one just needs enough to satisfy
  # Composer's dependency resolution.
  phpForBuild = php84.buildEnv {
    extensions = ({ enabled, all }: enabled ++ (with all; [
      curl intl gd gmp apcu pdo pdo_sqlite
    ]));
  };

in phpForBuild.buildComposerProject (finalAttrs: {
  pname   = "shlink";
  version = "5.0.1";

  src = fetchFromGitHub {
    owner = "shlinkio";
    repo  = "shlink";
    rev   = "v${finalAttrs.version}";
    # Run:
    #   nix-prefetch-url --unpack https://github.com/shlinkio/shlink/archive/refs/tags/v5.0.1.tar.gz
    # and paste the sri hash here:
    sha256 = "1lr0p5lx54i3ylc9zaaifha2kcm8d4mn5a3fqkg3gzcpw55z0w1b";
  };

  # Fixed-output hash of the vendor/ directory produced by
  # `composer install --no-dev --optimize-autoloader`.
  # To obtain it:
  #   1. Set this to lib.fakeHash
  #   2. Run: nix build .#shlink 2>&1 | grep "got:"
  #   3. Paste the printed sri hash here.
  vendorHash = "sha256-tPS0YaJwGMbsMIiTt7ol23fICvNVBX48yjjH61ZckQ8=";

  composerLock = ./composer.lock;

  # Pass our phpForBuild so the composer step uses the same interpreter
  # we declared above (the one with the required extensions).
  php = phpForBuild;

  postInstall = ''
    # Remove any bundled RoadRunner binary — wrong ELF for this host, and
    # the module uses php-fpm so rr is never needed at runtime.
    rm -f "$out/bin/rr"

    # Patch PHP shebang lines in CLI scripts to the Nix store path.
    # The module's phpfpm pool uses its own phpWithExts at runtime; we
    # point at phpForBuild here purely so the scripts are self-contained
    # in the store.
    phpBin="${lib.getBin phpForBuild}/bin/php"
    for script in "$out/bin/"*; do
      [ -f "$script" ] || continue
      head -1 "$script" | grep -q '^#!' || continue
      substituteInPlace "$script" \
        --replace-fail "#!/usr/bin/env php"   "#!$phpBin" \
        --replace-fail "#!/usr/local/bin/php" "#!$phpBin" \
        --replace-fail "#!/usr/bin/php"       "#!$phpBin"
    done

    # NixOS: redirect the application root chdir to a writable work directory.
    # Without this, config/container.php would chdir to dirname(__DIR__) which
    # is the read-only Nix store, making all relative data/* paths unwritable.
    # The NixOS module sets SHLINK_WORK_DIR to the writable state directory and
    # populates it with symlinks into the store at service start.
    substituteInPlace "$out/share/php/shlink/config/container.php" \
      --replace-fail \
        'chdir(dirname(__DIR__));' \
        'chdir(getenv("SHLINK_WORK_DIR") ?: dirname(__DIR__));'

    # NixOS: override config entries that use __DIR__-based absolute paths.
    # locks.global.php and geolite2.global.php hard-code paths relative to
    # their own __FILE__ location, which resolves to the read-only store.
    # This file is loaded last (zz- prefix sorts after all existing files)
    # and its values override the store-relative ones via ConfigAggregator
    # array merging.  SHLINK_DATA_DIR is set by the NixOS module.
    cat > "$out/share/php/shlink/config/autoload/zz-nixos-paths.global.php" << 'EOF'
<?php
declare(strict_types=1);

$dataDir = rtrim(getenv('SHLINK_DATA_DIR') ?: (getcwd() . '/data'), '/');

return [
    'locks'    => ['locks_dir'   => $dataDir . '/locks'],
    'geolite2' => [
        'db_location' => $dataDir . '/GeoLite2-City.mmdb',
        'temp_dir'    => $dataDir . '/temp-geolite',
    ],
];
EOF
  '';

  meta = with lib; {
    description = "The definitive self-hosted URL shortener";
    longDescription = ''
      Shlink is a self-hosted PHP URL shortener with a REST API, CLI, visit
      analytics (including optional geolocation), custom slugs, multi-domain
      support, and optional real-time updates via Mercure.
    '';
    homepage    = "https://shlink.io";
    license     = licenses.mit;
    platforms   = platforms.linux;
    maintainers = [ ];
  };
})

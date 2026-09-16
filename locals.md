locals {
  ca_path = "/etc/gitlab-runner/certs/ca.crt"

  # Every well-known bundle location, all sourced from the same host file.
  ca_mount_targets = [
    local.ca_path,                                      # canonical — env vars point here
    "/etc/ssl/certs/ca-certificates.crt",               # Debian, Ubuntu, Alpine
    "/etc/ssl/cert.pem",                                # Alpine, BSD-style OpenSSL
    "/etc/ssl/certs/ca-bundle.crt",                     # some RHEL-derived images
    "/etc/pki/tls/certs/ca-bundle.crt",                 # RHEL, Rocky, Fedora, AL2023
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",# RHEL extracted store
    "/etc/ssl/ca-bundle.pem",                           # SUSE, openSUSE
  ]

  ca_volumes = [
    for target in local.ca_mount_targets :
    "${var.host_ca_path}:${target}:ro"
  ]

  default_environment = [
    # OpenSSL / system store — curl, wget, Go, Ruby, PHP, most CLIs
    "SSL_CERT_FILE=${local.ca_path}",
    "SSL_CERT_DIR=/etc/ssl/certs",
    "CURL_CA_BUNDLE=${local.ca_path}",

    # git — does not reliably read SSL_CERT_FILE
    "GIT_SSL_CAINFO=${local.ca_path}",

    # Node and npm — own CA list, ignores the system store
    "NODE_EXTRA_CA_CERTS=${local.ca_path}",
    "NPM_CONFIG_CAFILE=${local.ca_path}",

    # Python — requests/certifi and pip need telling separately
    "REQUESTS_CA_BUNDLE=${local.ca_path}",
    "PIP_CERT=${local.ca_path}",

    # AWS CLI and SDKs
    "AWS_CA_BUNDLE=${local.ca_path}",

    # Rust, PHP, Deno
    "CARGO_HTTP_CAINFO=${local.ca_path}",
    "COMPOSER_CAFILE=${local.ca_path}",
    "DENO_CERT=${local.ca_path}",
  ]

  environment = concat(local.default_environment, var.extra_environment)
}

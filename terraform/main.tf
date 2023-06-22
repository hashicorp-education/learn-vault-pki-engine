# step 1.1 and 1.2
resource "vault_mount" "pki" {
  path        = "pki-example"
  type        = "pki"
  description = "This is an example PKI mount"

  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = local.ttl 
}

## both root and intermediate needed for section 8
resource "vault_pki_secret_backend_key" "root" {
  backend  = vault_mount.pki.path
  type     = "internal"
  key_name = "my-test-root-key"
  key_type = "rsa"
  key_bits = "4096"
}

resource "vault_pki_secret_backend_key" "intermediate" {
  backend  = vault_mount.pki-int.path
  type     = "internal"
  key_name = "my-test-int-key"
  key_type = "rsa"
  key_bits = "4096"
}

# 1.3
resource "vault_pki_secret_backend_root_cert" "root_2023" {
  backend     = vault_mount.pki.path
  type        = "internal"
  common_name = "example.com"
  ttl         = local.ttl
  issuer_name = "root-2023" # set initial name
  key_ref     = vault_pki_secret_backend_key.root.key_id
}

resource "local_file" "root_2023_cert" {
  content  = vault_pki_secret_backend_root_cert.root_2023.certificate
  filename = "root_2022_ca.crt"
}

# used to update name and properties
# manages lifecycle of existing issuer
resource "vault_pki_secret_backend_issuer" "root" {
  backend     = vault_mount.pki.path
  issuer_ref  = vault_pki_secret_backend_root_cert.root_2023.issuer_id
  issuer_name = "root-2023"
}

# 1.6
resource "vault_pki_secret_backend_role" "role" {
  backend          = vault_mount.pki.path
  name             = "2023-servers-role"
  ttl              = 86400
  allow_ip_sans    = true
  key_type         = "rsa"
  key_bits         = 4096
  allowed_domains  = ["example.com", "my.domain"]
  allow_subdomains = true
  allow_any_name   = true
}

# 1.7
resource "vault_pki_secret_backend_config_urls" "config-urls" {
   backend = vault_mount.pki.path
   issuing_certificates    = ["http://localhost:8200/v1/pki/ca"]
   crl_distribution_points = ["http://localhost:8200/v1/pki/crl"]
}

# vault secrets enable -path=pki_int pki
# vault secrets tune -max-lease-ttl=43800h pki_int

resource "vault_mount" "pki-int" {
  path        = "pki_int_example"
  type        = "pki"
  description = "This is an example intermediate PKI mount"

  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = 157680000
}

# vault write -format=json pki_int/intermediate/generate/internal \
#      common_name="example.com Intermediate Authority" \
#      issuer_name="example-dot-com-intermediate" \
#      | jq -r '.data.csr' > pki_intermediate.csr

resource "vault_pki_secret_backend_intermediate_cert_request" "csr-request" {
  backend     = vault_mount.pki-int.path
  type        = vault_pki_secret_backend_root_cert.root_2023.type
  common_name = "example.com Intermediate Authority"
  ## key ref?
}

resource "local_file" "csr_request_cert" {
  content  = vault_pki_secret_backend_intermediate_cert_request.csr-request.csr
  filename = "pki_intermediate.csr"
}

# vault write -format=json pki/root/sign-intermediate \
#      issuer_ref="root-2022" \
#      csr=@pki_intermediate.csr \
#      format=pem_bundle ttl="43800h" \
#      | jq -r '.data.certificate' > intermediate.cert.pem

resource "vault_pki_secret_backend_root_sign_intermediate" "intermediate" {
  backend     = vault_mount.pki.path
  csr         = vault_pki_secret_backend_intermediate_cert_request.csr-request.csr
  common_name = "Intermediate CA"
  format      = "pem_bundle"
  ttl         = 43800
  issuer_ref  = vault_pki_secret_backend_root_cert.root_2023.issuer_id
}

resource "local_file" "intermediate_ca_cert" {
  content  = vault_pki_secret_backend_root_sign_intermediate.intermediate.certificate
  filename = "intermediate.cert.pem"
}

# vault write pki_int/intermediate/set-signed certificate=@intermediate.cert.pem

resource "vault_pki_secret_backend_intermediate_set_signed" "intermediate" {
  backend     = vault_mount.pki-int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.intermediate.certificate
}

resource "vault_pki_secret_backend_issuer" "intermediate" {
  backend     = vault_mount.pki-int.path
  issuer_ref  = vault_pki_secret_backend_intermediate_set_signed.intermediate.imported_issuers[0]
  issuer_name = "intermediate-issuer"
}

# how do we verify it?  vault read...  did not work
# vault list pki_int_example/issuer


# vault write pki_int/roles/example-dot-com \
#      issuer_ref="$(vault read -field=default pki_int/config/issuers)" \
#      allowed_domains="example.com" \
#      allow_subdomains=true \
#      max_ttl="720h"

resource "vault_pki_secret_backend_role" "intermediate_role" {
  backend          = vault_mount.pki-int.path
  issuer_ref       = vault_pki_secret_backend_issuer.intermediate.issuer_ref
  name             = "example-dot-com"
  ttl              = 86400
  max_ttl          = 2592000
  allow_ip_sans    = true
  key_type         = "rsa"
  key_bits         = 4096
  allowed_domains  = ["example.com"]
  allow_subdomains = true
# add later if there are problems
#   allowed_uri_sans = ["spiffe://test.my.domain"]
#   key_usage        = ["DigitalSignature", "KeyAgreement", "KeyEncipherment"]
}

#  step4: request new cert for URL
#  vault write pki_int/issue/example-dot-com common_name="test.example.com" ttl="24h"

resource "vault_pki_secret_backend_cert" "app" {
  issuer_ref = vault_pki_secret_backend_issuer.intermediate.issuer_ref
#   backend    = vault_mount.pki-int.path
  backend    = vault_pki_secret_backend_role.intermediate_role.backend
  name       = vault_pki_secret_backend_role.intermediate_role.name
  common_name = "test1.example.com"
  ttl         = 3600
}

# step 5, 6 7 not possible via TF
# step 8 is part of demo



# resource "vault_mount" "initial" {
#   path                      = "pki-root-old"
#   type                      = "pki"
#   description               = "old root mount"
#   default_lease_ttl_seconds = local.ttl
#   max_lease_ttl_seconds     = local.ttl
# }

# resource "vault_mount" "intermediate" {
#   path                      = "pki-intermediate"
#   type                      = "pki"
#   description               = "test intermediate"
#   default_lease_ttl_seconds = local.ttl
#   max_lease_ttl_seconds     = local.ttl
# }

# ## needed for section 8
# resource "vault_pki_secret_backend_key" "root" {
#   backend  = vault_mount.pki.path
#   type     = "internal"
#   key_name = "my-test-root-key"
#   key_type = "rsa"
#   key_bits = "4096"
# }

# ## needed for section 8
# resource "vault_pki_secret_backend_key" "intermediate" {
#   backend  = vault_mount.pki-int.path
#   type     = "internal"
#   key_name = "my-test-int-key"
#   key_type = "rsa"
#   key_bits = "4096"
# }

# resource "vault_pki_secret_backend_root_cert" "initial" {
#   backend     = vault_mount.pki.path
#   type        = "existing"
#   common_name = "Demo Root R1"
#   ttl         = local.ttl
#   key_ref     = vault_pki_secret_backend_key.root.key_id
# }

# Track issuer created by root cert via TF
# update the name of the issuer
# resource "vault_pki_secret_backend_issuer" "issuer" {
#   backend     = vault_mount.pki.path
#   issuer_ref  = vault_pki_secret_backend_root_cert.root_2023.issuer_id
#   issuer_name = "initial-root-issuer"
# }

# resource "vault_pki_secret_backend_intermediate_cert_request" "initial" {
#   backend     = vault_mount.pki-int.path
#   type        = "existing"
#   common_name = "Demo Int X1"
#   key_ref     = vault_pki_secret_backend_key.intermediate.key_id
# }


# resource "vault_pki_secret_backend_root_sign_intermediate" "initial" {
#   backend               = vault_mount.pki.path
#   csr                   = vault_pki_secret_backend_intermediate_cert_request.csr-request.csr
#   common_name           = "Demo Sign S1"
#   permitted_dns_domains = [".test.my.domain"]
#   issuer_ref            = vault_pki_secret_backend_root_cert.root_2023.issuer_id
# }



# resource "vault_pki_secret_backend_intermediate_set_signed" "initial" {
#   backend     = vault_mount.pki-int.path
#   certificate = vault_pki_secret_backend_root_sign_intermediate.intermediate.certificate
# }

# resource "vault_pki_secret_backend_issuer" "issuer_int_initial" {
#   backend     = vault_mount.pki-int.path
#   issuer_ref  = vault_pki_secret_backend_intermediate_set_signed.initial.imported_issuers[0]
#   issuer_name = "initial-intermediate-issuer"
# }

# resource "vault_pki_secret_backend_role" "initial" {
#   backend          = vault_mount.pki-int.path
#   name             = "test"
#   allowed_domains  = ["test.my.domain"]
#   allow_subdomains = true
#   allowed_uri_sans = ["spiffe://test.my.domain"]
#   max_ttl          = local.ttl
#   key_usage        = ["DigitalSignature", "KeyAgreement", "KeyEncipherment"]
#   issuer_ref       = vault_pki_secret_backend_issuer.intermediate.issuer_ref
# }

# resource "vault_pki_secret_backend_cert" "initial" {
#   backend     = vault_pki_secret_backend_role.intermediate_role.backend
#   name        = vault_pki_secret_backend_role.intermediate_role.name
#   common_name = "cert1.test.my.domain"
#   ttl         = "1h"
#   issuer_ref  = vault_pki_secret_backend_role.intermediate_role.issuer_ref
# }

# Cross Sign Functionality

## Section 8 set up
## Create new parent root mount
resource "vault_mount" "new" {
  path                      = "pki-root-new"
  type                      = "pki"
  description               = "new root mount"
  default_lease_ttl_seconds = local.ttl
  max_lease_ttl_seconds     = local.ttl
}

## Generate root cert for new mount
resource "vault_pki_secret_backend_root_cert" "new" {
  backend     = vault_mount.new.path
  type        = "internal"
  common_name = "Demo Root R2"
  ttl         = local.ttl
}

# Track issuer created by root cert via TF
resource "vault_pki_secret_backend_issuer" "issuer_new_root" {
  backend     = vault_mount.new.path
  issuer_ref  = vault_pki_secret_backend_root_cert.new.issuer_id
  issuer_name = "new-root-issuer"
}

# 8.1 - creates a new intermediate
# vault write -format=json pki/intermediate/cross-sign \
#       common_name="example.com" \
#       key_ref="$(vault read pki/issuer/root-2023 \
#       | grep -i key_id | awk '{print $2}')" \
#       | jq -r '.data.csr' \
#       | tee cross-signed-intermediate.csr


## Create new CSR
resource "vault_pki_secret_backend_intermediate_cert_request" "new" {
  backend     = vault_mount.pki-int.path
  type        = "existing"
  common_name = "Demo Int X2"
  # uses key ID info from previously existing CSR
  key_ref = vault_pki_secret_backend_intermediate_cert_request.csr-request.key_id
}

# 8.2 - sign intermediate
# vault write -format=json pki/issuer/root-2022/sign-intermediate \
#       common_name="example.com" \
#       csr=@cross-signed-intermediate.csr \
#       | jq -r '.data.certificate' | tee cross-signed-intermediate.crt

## Sign CSR with new parent
resource "vault_pki_secret_backend_root_sign_intermediate" "new" {
  backend               = vault_mount.new.path
  csr                   = vault_pki_secret_backend_intermediate_cert_request.new.csr
  common_name           = "Demo Sign S1"
  permitted_dns_domains = [".test.my.domain"]
  issuer_ref            = vault_pki_secret_backend_root_cert.new.issuer_id
}

# 8.3
# vault write pki/intermediate/set-signed \
#       certificate=@cross-signed-intermediate.crt
# ??

## Import new issuers into existing intermediate mount
resource "vault_pki_secret_backend_intermediate_set_signed" "new" {
  backend     = vault_mount.pki-int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.new.certificate
}

resource "vault_pki_secret_backend_issuer" "issuer_int_new" {
  backend     = vault_mount.pki-int.path
  issuer_ref  = vault_pki_secret_backend_intermediate_set_signed.new.imported_issuers[0]
  issuer_name = "new-intermediate-issuer-updated"
}

# 8.4 - print 
# vault read pki/issuer/root-2023
# confirm multiple certs in print out per 8.4 

## Intermediate mount can now generate certs with new root issuer
resource "vault_pki_secret_backend_cert" "new" {
  backend     = vault_pki_secret_backend_role.intermediate_role.backend
  name        = vault_pki_secret_backend_role.intermediate_role.name
  common_name = "test2.example.com"
  ttl         = "1h"
  issuer_ref  = vault_pki_secret_backend_issuer.issuer_int_new.issuer_ref
}

# TODO: add back in after confirmation of functionality
# check with Vinay if should be included
# # Import issuer or key data to aid in migration
# data "vault_pki_secret_backend_keys" "initial" {
#   backend = vault_pki_secret_backend_root_sign_intermediate.intermediate.backend
# }

# data "vault_pki_secret_backend_issuers" "initial" {
#   backend = vault_pki_secret_backend_root_sign_intermediate.intermediate.backend
# }

# data "vault_pki_secret_backend_key" "missing" {
#   backend = vault_mount.pki.path
#   key_ref = data.vault_pki_secret_backend_keys.initial.keys[0]
# }

# data "vault_pki_secret_backend_issuer" "missing" {
#   backend    = vault_pki_secret_backend_root_sign_intermediate.intermediate.backend
#   issuer_ref = data.vault_pki_secret_backend_issuers.initial.keys[0]
# }


## Extra bits for verification!
resource "local_file" "initial_leaf_cert" {
  content  = vault_pki_secret_backend_cert.app.certificate
  filename = "initial_cert.pem"
}

resource "local_file" "new_leaf_cert" {
  content  = vault_pki_secret_backend_cert.new.certificate
  filename = "new_cert.pem"
}

# resource "local_file" "initial_root" {
#   content  = vault_pki_secret_backend_root_cert.root_2023.certificate
#   filename = "initial_root_cert.pem"
# }

resource "local_file" "new_root" {
  content  = vault_pki_secret_backend_root_cert.new.certificate
  filename = "new_root_cert.pem"
}

resource "local_file" "initial_intermediate" {
  content  = vault_pki_secret_backend_root_sign_intermediate.intermediate.certificate
  filename = "initial_ICA.pem"
}

resource "local_file" "new_intermediate" {
  content  = vault_pki_secret_backend_root_sign_intermediate.new.certificate
  filename = "new_ICA.pem"
}

# step 9, 10 not in TF
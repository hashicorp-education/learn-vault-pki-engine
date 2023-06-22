variable "vault_addr" {
   type = string
   default = "http://localhost:8200"
}

## Initial setup of root and intermediate
locals {
  ttl = "315360000"
}
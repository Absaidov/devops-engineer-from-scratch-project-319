terraform {
  required_version = ">= 1.6.3"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }

    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.228.0"
    }
  }
}

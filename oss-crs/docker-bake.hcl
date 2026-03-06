variable "REGISTRY" {
  default = "local"
}

variable "VERSION" {
  default = "latest"
}

function "tags" {
  params = [name]
  result = [
    "${name}:${VERSION}",
    "${name}:latest"
  ]
}

group "default" {
  targets = ["fuzzing-brain-base"]
}

target "fuzzing-brain-base" {
  context    = "."
  dockerfile = "oss-crs/dockerfiles/base.Dockerfile"
  tags       = tags("fuzzing-brain-base")
}

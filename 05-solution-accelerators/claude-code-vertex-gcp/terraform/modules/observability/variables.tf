variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Region used for the BigQuery dataset."
  type        = string
}

variable "labels" {
  description = "Resource labels."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "Number of days to retain gateway log entries in the BigQuery dataset."
  type        = number
  default     = 90
}

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

variable "enable_looker_views" {
  description = "Create BigQuery views for Looker Studio. Enable after the log sink has created its first table (requires at least one gateway request)."
  type        = bool
  default     = false
}

variable "log_table_name" {
  description = "Name of the BigQuery table created by the Cloud Logging sink. Varies by GCP version; check the dataset in the BigQuery console. Common values: run_googleapis_com_stdout, run_googleapis_com_requests."
  type        = string
  default     = "run_googleapis_com_stdout"
}

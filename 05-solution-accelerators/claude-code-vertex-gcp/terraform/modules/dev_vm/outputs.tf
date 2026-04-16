output "instance_names" {
  description = "Names of the created VM instances."
  value       = [for vm in google_compute_instance.vm : vm.name]
}

output "ssh_command" {
  description = "gcloud command to SSH into the first instance via IAP."
  value = (
    length(google_compute_instance.vm) > 0
    ? format(
      "gcloud compute ssh --tunnel-through-iap --project=%s --zone=%s %s",
      var.project_id,
      var.zone,
      [for vm in google_compute_instance.vm : vm.name][0],
    )
    : ""
  )
}

output "service_account_email" {
  description = "Email of the VM's service account."
  value       = google_service_account.sa.email
}

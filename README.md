# Script to deploy PCF (OpsManager) on Azure

_Semi-automatic as there is still a large amount of configurations to be completed manually on `OpsManager`._

## Note

* `Azure Marketplace` template solution recommended (but they some times fail, hence there was this script)
* `Terraform` solution recommended
* Try to use `install-ops-manager-Manual` instead of `install-ops-manager-ARM` as `ARM` template provided by `Pivotal` might change from time to time, while it sometimes just fails
* Drafted years ago, already forgotten why it is not written for `bash` in the first place, `GO POWERSHELL~! GO WSL~!`

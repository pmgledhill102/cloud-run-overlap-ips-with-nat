# Cloud Run - overlapping IP ranges using Private NAT

I want to prove the different ways in which Cloud Run can use overlapping IP ranges in different VPCs, yet still be able to have a compute instance talk to each of them.

Initial design thoughts:

- 5 x VPC networks
- 5 x Identical large non-routable Class E subnets in each - 240.0.0.0/8, 241.0.0.0/8, etc.
- 10 x Cloud Run services in each subnet (10x5x5 in total)... maxInstances=20, minInstances=0, maxConcurrency=1, with Request-based billing so it scales to zero cost
- all use same container image, that just does a 10 second on request
- 5 x non-overlapping small subnets in each - 10 IP addresses
- VPC networks connected with VPC peering, with non-routable ranges excluded (it wouldn't work anyway they overlap)
- does not use NCC
- 1 of the VPCs has an additional unique routable subnet for a compute instance
- Compute instance, that can have ssh commands to call each/any of the cloud run services
- private only networking throughout... no public IP addresses, and private networking switches on all cloud run and compute instances

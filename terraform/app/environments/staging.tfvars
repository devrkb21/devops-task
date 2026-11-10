environment        = "staging"
instance_type      = "t3.micro"
log_retention_days = 14
# Tip: restrict staging to your own IP, e.g. ["203.0.113.10/32"]
allowed_cidrs = ["0.0.0.0/0"]

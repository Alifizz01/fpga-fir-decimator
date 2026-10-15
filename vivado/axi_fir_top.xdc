# Out-of-context constraints: 100 MHz target on aclk. No I/O pins (OOC build).
create_clock -name aclk -period 10.000 [get_ports aclk]

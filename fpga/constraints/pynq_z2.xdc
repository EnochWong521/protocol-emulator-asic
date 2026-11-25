set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk_125]
create_clock -name clk_125 -period 8.000 [get_ports clk_125]

set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports reset_sw]

set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {gpio[0]}]
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports {gpio[1]}]
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports {gpio[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {gpio[3]}]

# clock debug
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports clk_debug]
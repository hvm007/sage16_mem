## =============================================================================
## flow/fpga/synth_fpga.tcl  —  Vivado synthesis + implementation for sage16_mem
##
## Targets Digilent Basys 3 (Xilinx Artix-7 XC7A35T-1CPG236C).
## Out-of-context (OOC) synthesis: no top-level pin constraints needed for
## paper-quality area/timing numbers.  For board deployment, point at the
## board XDC instead (constraints/basys3.xdc).
##
## Usage:
##   vivado -mode batch -source flow/fpga/synth_fpga.tcl \
##          -tclargs <top_module> <period_ns> <mode>
##     top_module : sage16_mem_top (default) | sage16_4x4_mac | sram_1rw_256x32
##     period_ns  : target clock period, e.g. 5.000 (200 MHz)
##     mode       : ooc | board (ooc = no XDC pin constraints; board = basys3.xdc)
##
## Outputs (reports/<top>/):
##   util_post_synth.rpt, util_post_route.rpt
##   timing_post_route.rpt
##   power_post_route.rpt
##   <top>_post_route.dcp
## =============================================================================

set top_module   [lindex $argv 0]
if {$top_module eq ""} { set top_module sage16_mem_top }

set period_ns    [lindex $argv 1]
if {$period_ns eq ""} { set period_ns 5.000 }

set mode         [lindex $argv 2]
if {$mode eq ""} { set mode ooc }

set part         xc7a35tcpg236-1
set rtl_dir      [file normalize [file dirname [info script]]/../../rtl]
set sim_dir      [file normalize [file dirname [info script]]/../../sim]
set out_dir      [file normalize [file dirname [info script]]/../../reports/$top_module]
set xdc_dir      [file normalize [file dirname [info script]]/../../constraints]

file mkdir $out_dir
puts "INFO: top=$top_module  period=${period_ns}ns  mode=$mode  out=$out_dir"

## ---------- read sources ----------
read_verilog [glob -directory $rtl_dir *.v]

## Define FPGA_BRAM so sram_1rw_256x32 infers BRAM (not ASIC macro)
set_property verilog_define {FPGA_BRAM} [current_fileset]

## ---------- constraints ----------
read_xdc [list]   ;# clear default
if {$mode eq "board"} {
    set xdc [file join $xdc_dir basys3.xdc]
    if {[file exists $xdc]} {
        read_xdc $xdc
        puts "INFO: using board XDC $xdc"
    } else {
        puts "WARN: $xdc not found, falling back to OOC clock-only"
        set mode ooc
    }
}

if {$mode eq "ooc"} {
    set tmp_xdc [file join $out_dir _clock_only.xdc]
    set fh [open $tmp_xdc w]
    puts $fh "create_clock -name clk -period $period_ns \[get_ports clk\]"
    puts $fh "set_input_delay -clock clk 0.1 \[all_inputs\]"
    puts $fh "set_output_delay -clock clk 0.1 \[all_outputs\]"
    close $fh
    read_xdc $tmp_xdc
}

## ---------- synthesis ----------
synth_design -top $top_module -part $part \
             [expr {$mode eq "ooc" ? "-mode out_of_context" : ""}] \
             -flatten_hierarchy rebuilt

write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $out_dir util_post_synth.rpt]
report_timing_summary -file [file join $out_dir timing_post_synth.rpt]

## ---------- implementation ----------
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $out_dir ${top_module}_post_route.dcp]
report_utilization -file [file join $out_dir util_post_route.rpt]
report_timing_summary -file [file join $out_dir timing_post_route.rpt]
report_power -file [file join $out_dir power_post_route.rpt]
report_design_analysis -file [file join $out_dir design_analysis.rpt]

puts "INFO: synthesis + PnR complete. Reports under $out_dir"
exit

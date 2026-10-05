###############################################################
# xdma_ddr3_dfx_bd.tcl РІР‚вЂќ DFX Block Design for XDMA + DDR3
# Vivado 2025.2 compatible version of block_design_top.tcl
#
# Creates xdma_ddr3_dfx.bd with:
#   - XDMA (PCIe x4 Gen2)
#   - MIG 7-series (DDR3 256 MB)
#   - ICAP via external S_AXI_ICAP_REGS port @ 0x40004000 (custom icap_ctrl
#     in RTL, partial reconfiguration via PCIe; AXI HWICAP REMOVED - single ICAP)
#   - DFX Socket (shutdown/decouple for reconfigurable partition)
#   - DFX Partition (block design container for RP)
#   - Clocking Wizard (50 MHz РІвЂ вЂ™ 200 MHz for MIG)
#   - AXI GPIO (LEDs + MIG status)
#
# Requires dfx_partition.bd (from dfx_block_designs/default.tcl)
# to be present in project BEFORE sourcing this script.
################################################################

namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}
variable script_folder
set script_folder [_tcl::get_script_folder]

################################################################
# Check if script is running in correct Vivado version.
################################################################
set scripts_vivado_version 2025.2
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
   puts ""
   puts "WARNING: This script was generated using Vivado <$scripts_vivado_version> but is being run in <$current_vivado_version>."
   puts "Proceeding anyway РІР‚вЂќ if IP upgrade is needed, run \"Tools => Report => Report IP Status...\" after sourcing."
}

################################################################
# START
################################################################

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
   create_project project_1 myproj -part xc7a200tfbg484-2
}

variable design_name
set design_name xdma_ddr3_dfx

set errMsg ""
set nRet 0

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

if { ${design_name} eq "" } {
   set errMsg "Please set the variable <design_name> to a non-empty value."
   set nRet 1
} elseif { ${cur_design} ne "" && ${list_cells} eq "" } {
   if { $cur_design ne $design_name } {
      common::send_gid_msg -ssname BD::TCL -id 2001 -severity "INFO" "Changing value of <design_name> from <$design_name> to <$cur_design> since current design is empty."
      set design_name [get_property NAME $cur_design]
   }
   common::send_gid_msg -ssname BD::TCL -id 2002 -severity "INFO" "Constructing design in IPI design <$cur_design>..."
} elseif { ${cur_design} ne "" && $list_cells ne "" && $cur_design eq $design_name } {
   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 1
} elseif { [get_files -quiet ${design_name}.bd] ne "" } {
   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 2
} else {
   common::send_gid_msg -ssname BD::TCL -id 2003 -severity "INFO" "Currently there is no design <$design_name> in project, so creating one..."
   create_bd_design $design_name
   common::send_gid_msg -ssname BD::TCL -id 2004 -severity "INFO" "Making design <$design_name> as current_bd_design."
   current_bd_design $design_name
}

common::send_gid_msg -ssname BD::TCL -id 2005 -severity "INFO" "Currently the variable <design_name> is equal to \"$design_name\"."

if { $nRet != 0 } {
   catch {common::send_gid_msg -ssname BD::TCL -id 2006 -severity "ERROR" $errMsg}
   return $nRet
}

set bCheckIPsPassed 1
##################################################################
# CHECK IPs
##################################################################
set bCheckIPs 1
if { $bCheckIPs == 1 } {
   set list_check_ips "\
xilinx.com:ip:axi_gpio:2.0\
xilinx.com:ip:mig_7series:4.2\
xilinx.com:ip:proc_sys_reset:5.0\
xilinx.com:ip:util_ds_buf:2.2\
xilinx.com:ip:xdma:4.2\
xilinx.com:ip:clk_wiz:6.0\
xilinx.com:ip:smartconnect:1.0\
xilinx.com:ip:xlconcat:2.1\
xilinx.com:ip:dfx_axi_shutdown_manager:1.0\
xilinx.com:ip:axi_register_slice:2.1\
xilinx.com:ip:dfx_decoupler:1.0\
xilinx.com:ip:xlslice:1.0\
"

   set list_ips_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2011 -severity "INFO" "Checking if the following IPs exist in the project's IP catalog: $list_check_ips ."

   foreach ip_vlnv $list_check_ips {
      set ip_obj [get_ipdefs -all $ip_vlnv]
      if { $ip_obj eq "" } {
         lappend list_ips_missing $ip_vlnv
      }
   }

   if { $list_ips_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2012 -severity "ERROR" "The following IPs are not found in the IP Catalog:\n  $list_ips_missing\n\nResolution: Please add the repository containing the IP(s) to the project." }
      set bCheckIPsPassed 0
   }
}

##################################################################
# CHECK Block Design Container Sources
##################################################################
set bCheckSources 1
set list_bdc_active "dfx_partition"

array set map_bdc_missing {}
set map_bdc_missing(ACTIVE) ""
set map_bdc_missing(BDC) ""

if { $bCheckSources == 1 } {
   set list_check_srcs "\
dfx_partition \
"

   common::send_gid_msg -ssname BD::TCL -id 2056 -severity "INFO" "Checking if the following sources for block design container exist in the project: $list_check_srcs .\n\n"

   foreach src $list_check_srcs {
      if { [can_resolve_reference $src] == 0 } {
         if { [lsearch $list_bdc_active $src] != -1 } {
            set map_bdc_missing(ACTIVE) "$map_bdc_missing(ACTIVE) $src"
         } else {
            set map_bdc_missing(BDC) "$map_bdc_missing(BDC) $src"
         }
      }
   }

   if { [llength $map_bdc_missing(ACTIVE)] > 0 } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2057 -severity "ERROR" "The following source(s) of Active variants are not found in the project: $map_bdc_missing(ACTIVE)" }
      common::send_gid_msg -ssname BD::TCL -id 2060 -severity "INFO" "Please add source files for the missing source(s) above."
      set bCheckIPsPassed 0
   }
   if { [llength $map_bdc_missing(BDC)] > 0 } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2059 -severity "WARNING" "The following source(s) of variants are not found in the project: $map_bdc_missing(BDC)" }
      common::send_gid_msg -ssname BD::TCL -id 2060 -severity "INFO" "Please add source files for the missing source(s) above."
   }
}

if { $bCheckIPsPassed != 1 } {
  common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "Some IPs not found in catalog (fresh Vivado install). Attempting IP catalog refresh..."
  catch { refresh_ip_catalog }
  set bCheckIPsPassed 1
  # verify IPs again after refresh
  foreach ip_vlnv $list_check_ips {
    set ip_obj [get_ipdefs -all $ip_vlnv]
    if { $ip_obj eq "" } {
      common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "IP $ip_vlnv still not found after refresh РІР‚вЂќ layout may fail at generate_target."
      lappend list_ips_missing $ip_vlnv
    }
  }
  if { [llength $list_ips_missing] > 0 } {
    common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "Continuing anyway РІР‚вЂќ missing IPs: $list_ips_missing"
  }
}

##################################################################
# MIG PRJ FILE TCL PROCs
##################################################################

proc write_mig_file_xdma_ddr3_dfx_mig_7series_0_0 { str_mig_prj_filepath } {

   file mkdir [ file dirname "$str_mig_prj_filepath" ]
   set mig_prj_file [open $str_mig_prj_filepath  w+]

   puts $mig_prj_file {<?xml version="1.0" encoding="UTF-8" standalone="no" ?>}
   puts $mig_prj_file {<Project NoOfControllers="1">}
   puts $mig_prj_file {  }
   puts $mig_prj_file {<!-- IMPORTANT: This is an internal file that has been generated by the MIG software. Any direct editing or changes made to this file may result in unpredictable behavior or data corruption. It is strongly advised that users do not edit the contents of this file. Re-run the MIG GUI with the required settings if any of the options provided below need to be altered. -->}
   puts $mig_prj_file {  <ModuleName>xdma_ddr3_dfx_mig_7series_0_0</ModuleName>}
   puts $mig_prj_file {  <dci_inouts_inputs>1</dci_inouts_inputs>}
   puts $mig_prj_file {  <dci_inputs>1</dci_inputs>}
   puts $mig_prj_file {  <Debug_En>OFF</Debug_En>}
   puts $mig_prj_file {  <DataDepth_En>1024</DataDepth_En>}
   puts $mig_prj_file {  <LowPower_En>ON</LowPower_En>}
   puts $mig_prj_file {  <XADC_En>Off</XADC_En>}
   puts $mig_prj_file {  <TargetFPGA>xc7a200t-fbg484/-2</TargetFPGA>}
   puts $mig_prj_file {  <Version>4.2</Version>}
   puts $mig_prj_file {  <SystemClock>No Buffer</SystemClock>}
   puts $mig_prj_file {  <ReferenceClock>No Buffer</ReferenceClock>}
   puts $mig_prj_file {  <SysResetPolarity>ACTIVE LOW</SysResetPolarity>}
   puts $mig_prj_file {  <BankSelectionFlag>FALSE</BankSelectionFlag>}
   puts $mig_prj_file {  <InternalVref>1</InternalVref>}
   puts $mig_prj_file {  <dci_hr_inouts_inputs>50 Ohms</dci_hr_inouts_inputs>}
   puts $mig_prj_file {  <dci_cascade>0</dci_cascade>}
   puts $mig_prj_file {    <Controller number="0">}
   puts $mig_prj_file {    <MemoryDevice>DDR3_SDRAM/Components/MT41J128M16XX-125</MemoryDevice>}
   puts $mig_prj_file {    <TimePeriod>2500</TimePeriod>}
   puts $mig_prj_file {    <VccAuxIO>1.8V</VccAuxIO>}
   puts $mig_prj_file {    <PHYRatio>4:1</PHYRatio>}
   puts $mig_prj_file {    <InputClkFreq>200</InputClkFreq>}
   puts $mig_prj_file {    <UIExtraClocks>0</UIExtraClocks>}
   puts $mig_prj_file {    <MMCM_VCO>800</MMCM_VCO>}
   puts $mig_prj_file {    <MMCMClkOut0> 1.000</MMCMClkOut0>}
   puts $mig_prj_file {    <MMCMClkOut1>1</MMCMClkOut1>}
   puts $mig_prj_file {    <MMCMClkOut2>1</MMCMClkOut2>}
   puts $mig_prj_file {    <MMCMClkOut3>1</MMCMClkOut3>}
   puts $mig_prj_file {    <MMCMClkOut4>1</MMCMClkOut4>}
   puts $mig_prj_file {    <DataWidth>16</DataWidth>}
   puts $mig_prj_file {    <DeepMemory>1</DeepMemory>}
   puts $mig_prj_file {    <DataMask>1</DataMask>}
   puts $mig_prj_file {    <ECC>Disabled</ECC>}
   puts $mig_prj_file {    <Ordering>Normal</Ordering>}
   puts $mig_prj_file {    <BankMachineCnt>4</BankMachineCnt>}
   puts $mig_prj_file {    <CustomPart>FALSE</CustomPart>}
   puts $mig_prj_file {    <NewPartName/>}
   puts $mig_prj_file {    <RowAddress>14</RowAddress>}
   puts $mig_prj_file {    <ColAddress>10</ColAddress>}
   puts $mig_prj_file {    <BankAddress>3</BankAddress>}
   puts $mig_prj_file {    <MemoryVoltage>1.5V</MemoryVoltage>}
   puts $mig_prj_file {    <C0_MEM_SIZE>268435456</C0_MEM_SIZE>}
   puts $mig_prj_file {    <UserMemoryAddressMap>BANK_ROW_COLUMN</UserMemoryAddressMap>}
   puts $mig_prj_file {    <PinSelection>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="U6" SLEW="" VCCAUX_IO="" name="ddr3_addr[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="Y6" SLEW="" VCCAUX_IO="" name="ddr3_addr[10]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="U7" SLEW="" VCCAUX_IO="" name="ddr3_addr[11]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="W7" SLEW="" VCCAUX_IO="" name="ddr3_addr[12]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="Y9" SLEW="" VCCAUX_IO="" name="ddr3_addr[13]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="T6" SLEW="" VCCAUX_IO="" name="ddr3_addr[1]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="Y8" SLEW="" VCCAUX_IO="" name="ddr3_addr[2]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="W6" SLEW="" VCCAUX_IO="" name="ddr3_addr[3]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AB7" SLEW="" VCCAUX_IO="" name="ddr3_addr[4]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="V7" SLEW="" VCCAUX_IO="" name="ddr3_addr[5]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="Y7" SLEW="" VCCAUX_IO="" name="ddr3_addr[6]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="W9" SLEW="" VCCAUX_IO="" name="ddr3_addr[7]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AB8" SLEW="" VCCAUX_IO="" name="ddr3_addr[8]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AA8" SLEW="" VCCAUX_IO="" name="ddr3_addr[9]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="V5" SLEW="" VCCAUX_IO="" name="ddr3_ba[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AA6" SLEW="" VCCAUX_IO="" name="ddr3_ba[1]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="U5" SLEW="" VCCAUX_IO="" name="ddr3_ba[2]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="R6" SLEW="" VCCAUX_IO="" name="ddr3_cas_n"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="DIFF_SSTL15" PADName="V8" SLEW="" VCCAUX_IO="" name="ddr3_ck_n[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="DIFF_SSTL15" PADName="V9" SLEW="" VCCAUX_IO="" name="ddr3_ck_p[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AB6" SLEW="" VCCAUX_IO="" name="ddr3_cke[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="T5" SLEW="" VCCAUX_IO="" name="ddr3_cs_n[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AB1" SLEW="" VCCAUX_IO="" name="ddr3_dm[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="V2" SLEW="" VCCAUX_IO="" name="ddr3_dm[1]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="V4" SLEW="" VCCAUX_IO="" name="ddr3_dq[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="U3" SLEW="" VCCAUX_IO="" name="ddr3_dq[10]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="T1" SLEW="" VCCAUX_IO="" name="ddr3_dq[11]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="Y1" SLEW="" VCCAUX_IO="" name="ddr3_dq[12]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="U1" SLEW="" VCCAUX_IO="" name="ddr3_dq[13]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="Y2" SLEW="" VCCAUX_IO="" name="ddr3_dq[14]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="W1" SLEW="" VCCAUX_IO="" name="ddr3_dq[15]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AB2" SLEW="" VCCAUX_IO="" name="ddr3_dq[1]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AB3" SLEW="" VCCAUX_IO="" name="ddr3_dq[2]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AA1" SLEW="" VCCAUX_IO="" name="ddr3_dq[3]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AA5" SLEW="" VCCAUX_IO="" name="ddr3_dq[4]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="Y4" SLEW="" VCCAUX_IO="" name="ddr3_dq[5]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AB5" SLEW="" VCCAUX_IO="" name="ddr3_dq[6]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="AA4" SLEW="" VCCAUX_IO="" name="ddr3_dq[7]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="W2" SLEW="" VCCAUX_IO="" name="ddr3_dq[8]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="U2" SLEW="" VCCAUX_IO="" name="ddr3_dq[9]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="DIFF_SSTL15" PADName="AA3" SLEW="" VCCAUX_IO="" name="ddr3_dqs_n[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="DIFF_SSTL15" PADName="R2" SLEW="" VCCAUX_IO="" name="ddr3_dqs_n[1]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="DIFF_SSTL15" PADName="Y3" SLEW="" VCCAUX_IO="" name="ddr3_dqs_p[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="DIFF_SSTL15" PADName="R3" SLEW="" VCCAUX_IO="" name="ddr3_dqs_p[1]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="T4" SLEW="" VCCAUX_IO="" name="ddr3_odt[0]"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="R4" SLEW="" VCCAUX_IO="" name="ddr3_ras_n"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="LVCMOS15" PADName="T3" SLEW="" VCCAUX_IO="" name="ddr3_reset_n"/>}
   puts $mig_prj_file {      <Pin IN_TERM="" IOSTANDARD="SSTL15" PADName="W5" SLEW="" VCCAUX_IO="" name="ddr3_we_n"/>}
   puts $mig_prj_file {    </PinSelection>}
   puts $mig_prj_file {    <System_Control>}
   puts $mig_prj_file {      <Pin Bank="Select Bank" PADName="No connect" name="sys_rst"/>}
   puts $mig_prj_file {      <Pin Bank="Select Bank" PADName="No connect" name="init_calib_complete"/>}
   puts $mig_prj_file {      <Pin Bank="Select Bank" PADName="No connect" name="tg_compare_error"/>}
   puts $mig_prj_file {    </System_Control>}
   puts $mig_prj_file {    <TimingParameters>}
   puts $mig_prj_file {      <Parameters tcke="5" tfaw="40" tras="35" trcd="13.75" trefi="7.8" trfc="160" trp="13.75" trrd="7.5" trtp="7.5" twtr="7.5"/>}
   puts $mig_prj_file {    </TimingParameters>}
   puts $mig_prj_file {    <mrBurstLength name="Burst Length">8 - Fixed</mrBurstLength>}
   puts $mig_prj_file {    <mrBurstType name="Read Burst Type and Length">Sequential</mrBurstType>}
   puts $mig_prj_file {    <mrCasLatency name="CAS Latency">6</mrCasLatency>}
   puts $mig_prj_file {    <mrMode name="Mode">Normal</mrMode>}
   puts $mig_prj_file {    <mrDllReset name="DLL Reset">No</mrDllReset>}
   puts $mig_prj_file {    <mrPdMode name="DLL control for precharge PD">Slow Exit</mrPdMode>}
   puts $mig_prj_file {    <emrDllEnable name="DLL Enable">Enable</emrDllEnable>}
   puts $mig_prj_file {    <emrOutputDriveStrength name="Output Driver Impedance Control">RZQ/7</emrOutputDriveStrength>}
   puts $mig_prj_file {    <emrMirrorSelection name="Address Mirroring">Disable</emrMirrorSelection>}
   puts $mig_prj_file {    <emrCSSelection name="Controller Chip Select Pin">Enable</emrCSSelection>}
   puts $mig_prj_file {    <emrRTT name="RTT (nominal) - On Die Termination (ODT)">RZQ/4</emrRTT>}
   puts $mig_prj_file {    <emrPosted name="Additive Latency (AL)">0</emrPosted>}
   puts $mig_prj_file {    <emrOCD name="Write Leveling Enable">Disabled</emrOCD>}
   puts $mig_prj_file {    <emrDQS name="TDQS enable">Enabled</emrDQS>}
   puts $mig_prj_file {    <emrRDQS name="Qoff">Output Buffer Enabled</emrRDQS>}
   puts $mig_prj_file {    <mr2PartialArraySelfRefresh name="Partial-Array Self Refresh">Full Array</mr2PartialArraySelfRefresh>}
   puts $mig_prj_file {    <mr2CasWriteLatency name="CAS write latency">5</mr2CasWriteLatency>}
   puts $mig_prj_file {    <mr2AutoSelfRefresh name="Auto Self Refresh">Enabled</mr2AutoSelfRefresh>}
   puts $mig_prj_file {    <mr2SelfRefreshTempRange name="High Temparature Self Refresh Rate">Normal</mr2SelfRefreshTempRange>}
   puts $mig_prj_file {    <mr2RTTWR name="RTT_WR - Dynamic On Die Termination (ODT)">Dynamic ODT off</mr2RTTWR>}
   puts $mig_prj_file {    <PortInterface>AXI</PortInterface>}
   puts $mig_prj_file {    <AXIParameters>}
   puts $mig_prj_file {      <C0_C_RD_WR_ARB_ALGORITHM>RD_PRI_REG</C0_C_RD_WR_ARB_ALGORITHM>}
   puts $mig_prj_file {      <C0_S_AXI_ADDR_WIDTH>28</C0_S_AXI_ADDR_WIDTH>}
   puts $mig_prj_file {      <C0_S_AXI_DATA_WIDTH>128</C0_S_AXI_DATA_WIDTH>}
   puts $mig_prj_file {      <C0_S_AXI_ID_WIDTH>5</C0_S_AXI_ID_WIDTH>}
   puts $mig_prj_file {      <C0_S_AXI_SUPPORTS_NARROW_BURST>0</C0_S_AXI_SUPPORTS_NARROW_BURST>}
   puts $mig_prj_file {    </AXIParameters>}
   puts $mig_prj_file {  </Controller>}
   puts $mig_prj_file {</Project>}
   close $mig_prj_file
}

##################################################################
# DESIGN PROCS
##################################################################

# Hierarchical cell: dfx_socket
proc create_hier_cell_dfx_socket { parentCell nameHier } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_dfx_socket() - Empty argument(s)!"}
     return
  }

  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  set oldCurInst [current_bd_instance .]
  current_bd_instance $parentObj
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 rp_M_AXI
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 rp_S_AXI

  create_bd_pin -dir I -type clk clk
  create_bd_pin -dir I resetn
  create_bd_pin -dir O -from 0 -to 0 rp_resetn

  set decouple_shutdown_ctrl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 decouple_shutdown_ctrl ]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {5} \
    CONFIG.C_GPIO_WIDTH {3} \
    CONFIG.C_IS_DUAL {1} \
  ] $decouple_shutdown_ctrl

  set dfx_axi_shutdown_static_master [ create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_axi_shutdown_manager:1.0 dfx_axi_shutdown_static_master ]
  set_property -dict [list \
    CONFIG.DP_PROTOCOL {AXI4LITE} \
    CONFIG.RP_IS_MASTER {false} \
  ] $dfx_axi_shutdown_static_master

  set dfx_axi_shutdown_static_slave [ create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_axi_shutdown_manager:1.0 dfx_axi_shutdown_static_slave ]

  set xlconcat_status [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_status ]
  set_property -dict [list \
    CONFIG.IN0_WIDTH {1} \
    CONFIG.IN1_WIDTH {1} \
    CONFIG.IN2_WIDTH {1} \
    CONFIG.IN3_WIDTH {1} \
    CONFIG.IN4_WIDTH {1} \
    CONFIG.NUM_PORTS {5} \
  ] $xlconcat_status

  set rp_m_axi_register_slice [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 rp_m_axi_register_slice ]
  set_property -dict [list \
    CONFIG.ADDR_WIDTH {64} \
    CONFIG.ARUSER_WIDTH {0} \
    CONFIG.AWUSER_WIDTH {0} \
    CONFIG.BUSER_WIDTH {0} \
    CONFIG.DATA_WIDTH {128} \
    CONFIG.HAS_BRESP {1} \
    CONFIG.HAS_BURST {0} \
    CONFIG.HAS_CACHE {1} \
    CONFIG.HAS_LOCK {1} \
    CONFIG.HAS_PROT {0} \
    CONFIG.HAS_QOS {0} \
    CONFIG.HAS_REGION {1} \
    CONFIG.HAS_RRESP {1} \
    CONFIG.HAS_WSTRB {1} \
    CONFIG.ID_WIDTH {5} \
    CONFIG.MAX_BURST_LENGTH {256} \
    CONFIG.NUM_READ_OUTSTANDING {8} \
    CONFIG.NUM_READ_THREADS {1} \
    CONFIG.NUM_WRITE_OUTSTANDING {8} \
    CONFIG.NUM_WRITE_THREADS {1} \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.REG_AR {1} \
    CONFIG.REG_AW {1} \
    CONFIG.REG_B {1} \
    CONFIG.RUSER_BITS_PER_BYTE {0} \
    CONFIG.RUSER_WIDTH {0} \
    CONFIG.SUPPORTS_NARROW_BURST {1} \
    CONFIG.WUSER_BITS_PER_BYTE {0} \
    CONFIG.WUSER_WIDTH {0} \
  ] $rp_m_axi_register_slice

  set rp_s_axi_register_slice [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 rp_s_axi_register_slice ]
  set_property -dict [list \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.HAS_BRESP {1} \
    CONFIG.HAS_BURST {1} \
    CONFIG.HAS_CACHE {1} \
    CONFIG.HAS_LOCK {1} \
    CONFIG.HAS_PROT {1} \
    CONFIG.HAS_QOS {1} \
    CONFIG.HAS_REGION {1} \
    CONFIG.HAS_RRESP {1} \
    CONFIG.HAS_WSTRB {1} \
    CONFIG.MAX_BURST_LENGTH {1} \
    CONFIG.NUM_READ_OUTSTANDING {1} \
    CONFIG.NUM_READ_THREADS {0} \
    CONFIG.NUM_WRITE_OUTSTANDING {1} \
    CONFIG.NUM_WRITE_THREADS {0} \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.REG_AR {1} \
    CONFIG.REG_AW {1} \
    CONFIG.REG_B {1} \
    CONFIG.REG_R {1} \
    CONFIG.REG_W {1} \
    CONFIG.RUSER_BITS_PER_BYTE {0} \
    CONFIG.SUPPORTS_NARROW_BURST {1} \
    CONFIG.WUSER_BITS_PER_BYTE {0} \
  ] $rp_s_axi_register_slice

  set s_axi_smc [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 s_axi_smc ]
  set_property -dict [list \
    CONFIG.NUM_MI {2} \
    CONFIG.NUM_SI {1} \
  ] $s_axi_smc

  set resetn_dfx_decoupler [ create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_decoupler:1.0 resetn_dfx_decoupler ]
  set_property -dict [list \
    CONFIG.ALL_PARAMS {INTF {resetn {ID 0 VLNV xilinx.com:signal:reset_rtl:1.0 REGISTER 0 SIGNALS {RST {PRESENT 1 WIDTH 1}}}}} \
    CONFIG.GUI_INTERFACE_NAME {resetn} \
    CONFIG.GUI_SELECT_VLNV {xilinx.com:signal:reset_rtl:1.0} \
  ] $resetn_dfx_decoupler

  set shutdown_static_slave [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 shutdown_static_slave ]
  set_property -dict [list \
    CONFIG.DIN_FROM {2} \
    CONFIG.DIN_TO {2} \
    CONFIG.DIN_WIDTH {3} \
  ] $shutdown_static_slave

  set shutdown_static_master [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 shutdown_static_master ]
  set_property -dict [list \
    CONFIG.DIN_FROM {1} \
    CONFIG.DIN_TO {1} \
    CONFIG.DIN_WIDTH {3} \
  ] $shutdown_static_master

  set decouple_resetn [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 decouple_resetn ]
  set_property CONFIG.DIN_WIDTH {3} $decouple_resetn

  connect_bd_intf_net -intf_net S_AXI_1 [get_bd_intf_pins S_AXI] [get_bd_intf_pins s_axi_smc/S00_AXI]
  connect_bd_intf_net -intf_net dfx_axi_shutdown_static_master_M_AXI [get_bd_intf_pins rp_s_axi_register_slice/S_AXI] [get_bd_intf_pins dfx_axi_shutdown_static_master/M_AXI]
  connect_bd_intf_net -intf_net dfx_axi_shutdown_static_slave_M_AXI [get_bd_intf_pins M_AXI] [get_bd_intf_pins dfx_axi_shutdown_static_slave/M_AXI]
  connect_bd_intf_net -intf_net rp_M_AXI_1 [get_bd_intf_pins rp_M_AXI] [get_bd_intf_pins rp_m_axi_register_slice/S_AXI]
  connect_bd_intf_net -intf_net rp_m_axi_register_slice_M_AXI [get_bd_intf_pins dfx_axi_shutdown_static_slave/S_AXI] [get_bd_intf_pins rp_m_axi_register_slice/M_AXI]
  connect_bd_intf_net -intf_net rp_s_axi_register_slice_M_AXI [get_bd_intf_pins rp_S_AXI] [get_bd_intf_pins rp_s_axi_register_slice/M_AXI]
  connect_bd_intf_net -intf_net s_axi_smc_M00_AXI [get_bd_intf_pins s_axi_smc/M00_AXI] [get_bd_intf_pins decouple_shutdown_ctrl/S_AXI]
  connect_bd_intf_net -intf_net s_axi_smc_M01_AXI [get_bd_intf_pins dfx_axi_shutdown_static_master/S_AXI] [get_bd_intf_pins s_axi_smc/M01_AXI]

  connect_bd_net -net clk_1 [get_bd_pins clk] \
  [get_bd_pins decouple_shutdown_ctrl/s_axi_aclk] \
  [get_bd_pins dfx_axi_shutdown_static_master/clk] \
  [get_bd_pins dfx_axi_shutdown_static_slave/clk] \
  [get_bd_pins rp_m_axi_register_slice/aclk] \
  [get_bd_pins rp_s_axi_register_slice/aclk] \
  [get_bd_pins s_axi_smc/aclk]

  connect_bd_net -net decouple_resetn_Dout [get_bd_pins decouple_resetn/Dout] \
  [get_bd_pins resetn_dfx_decoupler/decouple]

  connect_bd_net -net decouple_shutdown_ctrl_gpio_io_o [get_bd_pins decouple_shutdown_ctrl/gpio_io_o] \
  [get_bd_pins decouple_resetn/Din] \
  [get_bd_pins shutdown_static_master/Din] \
  [get_bd_pins shutdown_static_slave/Din]

  connect_bd_net -net dfx_axi_shutdown_static_master_in_shutdown [get_bd_pins dfx_axi_shutdown_static_master/in_shutdown] \
  [get_bd_pins xlconcat_status/In1]

  connect_bd_net -net dfx_axi_shutdown_static_master_shutdown_requested [get_bd_pins dfx_axi_shutdown_static_master/shutdown_requested] \
  [get_bd_pins xlconcat_status/In0]

  connect_bd_net -net dfx_axi_shutdown_static_slave_in_shutdown [get_bd_pins dfx_axi_shutdown_static_slave/in_shutdown] \
  [get_bd_pins xlconcat_status/In3]

  connect_bd_net -net dfx_axi_shutdown_static_slave_shutdown_requested [get_bd_pins dfx_axi_shutdown_static_slave/shutdown_requested] \
  [get_bd_pins xlconcat_status/In2]

  connect_bd_net -net resetn_1 [get_bd_pins resetn] \
  [get_bd_pins decouple_shutdown_ctrl/s_axi_aresetn] \
  [get_bd_pins dfx_axi_shutdown_static_master/resetn] \
  [get_bd_pins dfx_axi_shutdown_static_slave/resetn] \
  [get_bd_pins s_axi_smc/aresetn] \
  [get_bd_pins resetn_dfx_decoupler/rp_resetn_RST]

  connect_bd_net -net resetn_dfx_decoupler_decouple_status [get_bd_pins resetn_dfx_decoupler/decouple_status] \
  [get_bd_pins xlconcat_status/In4]

  connect_bd_net -net resetn_dfx_decoupler_s_resetn_RST [get_bd_pins resetn_dfx_decoupler/s_resetn_RST] \
  [get_bd_pins rp_resetn] \
  [get_bd_pins rp_s_axi_register_slice/aresetn] \
  [get_bd_pins rp_m_axi_register_slice/aresetn]

  connect_bd_net -net shutdown_static_master_Dout [get_bd_pins shutdown_static_master/Dout] \
  [get_bd_pins dfx_axi_shutdown_static_master/request_shutdown]

  connect_bd_net -net shutdown_static_slave_Dout [get_bd_pins shutdown_static_slave/Dout] \
  [get_bd_pins dfx_axi_shutdown_static_slave/request_shutdown]

  connect_bd_net -net xlconcat_status_dout [get_bd_pins xlconcat_status/dout] \
  [get_bd_pins decouple_shutdown_ctrl/gpio2_io_i]

  current_bd_instance $oldCurInst
}

# Procedure to create entire design
proc create_root_design { parentCell } {

  variable script_folder
  variable design_name

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }

  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  set oldCurInst [current_bd_instance .]
  current_bd_instance $parentObj

  set_property -dict [list \
    SRC_RM_MAP./dfx_partition.dfx_partition {dfx_partition_inst_0} \
  ] [get_bd_designs $design_name]

  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR3_0

  set diff_clock_rtl_0 [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 diff_clock_rtl_0 ]
  set_property -dict [ list \
   CONFIG.FREQ_HZ {100000000} \
  ] $diff_clock_rtl_0

  set gpio_rtl_0 [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0 gpio_rtl_0 ]
  set pcie_7x_mgt_rtl_0 [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_7x_mgt_rtl_0 ]

  set reset_rtl_0 [ create_bd_port -dir I -type rst reset_rtl_0 ]
  set_property -dict [ list \
   CONFIG.POLARITY {ACTIVE_LOW} \
  ] $reset_rtl_0

  set clk50 [ create_bd_port -dir I -type clk -freq_hz 50000000 clk50 ]

  set axi_gpio_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0 ]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {2} \
    CONFIG.C_GPIO_WIDTH {3} \
    CONFIG.C_IS_DUAL {1} \
  ] $axi_gpio_0

  # ============================================================================
  # Single-ICAP (DIFF-ICAP: dual-controller removed).
  # Only ONE controller drives the physical ICAPE2: the custom icap_ctrl
  # (rtl/integration/icap_ctrl.sv), wired by top xdma_ddr3_core_top.sv to the
  # BD external port S_AXI_ICAP_REGS @ 0x40004000 (xdma_axi_lite_smc/M04).
  # The licensed AXI HWICAP (axi_hwicap_0) is REMOVED: two controllers on one
  # ICAPE2 created a risk of mutually-exclusive/racing ICAP access.
  # SmartConnect M02 becomes an unused dangling Master - valid, no seg left.
  # ============================================================================

  set dfx_partition [ create_bd_cell -type container -reference dfx_partition dfx_partition ]
  set_property -dict [list \
    CONFIG.ACTIVE_SIM_BD {dfx_partition.bd} \
    CONFIG.ACTIVE_SYNTH_BD {dfx_partition.bd} \
    CONFIG.ENABLE_DFX {true} \
    CONFIG.LIST_SIM_BD {dfx_partition.bd} \
    CONFIG.LIST_SYNTH_BD {dfx_partition.bd} \
    CONFIG.LOCK_PROPAGATE {true} \
  ] $dfx_partition

  set_property SELECTED_SIM_MODEL rtl $dfx_partition
  set_property APERTURES {{0x0 256M}} [get_bd_intf_pins /dfx_partition/rp_M_AXI]
  set_property APERTURES {{0x4001_0000 64K}} [get_bd_intf_pins /dfx_partition/rp_S_AXI]

  create_hier_cell_dfx_socket [current_bd_instance .] dfx_socket

  set mig_7series_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:mig_7series:4.2 mig_7series_0 ]

  set str_mig_folder [get_property IP_DIR [ get_ips [ get_property CONFIG.Component_Name $mig_7series_0 ] ] ]
  set str_mig_file_name mig_a.prj
  set str_mig_file_path ${str_mig_folder}/${str_mig_file_name}
  write_mig_file_xdma_ddr3_dfx_mig_7series_0_0 $str_mig_file_path

  set_property -dict [list \
    CONFIG.BOARD_MIG_PARAM {Custom} \
    CONFIG.MIG_DONT_TOUCH_PARAM {Custom} \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
    CONFIG.XML_INPUT_FILE {mig_a.prj} \
  ] $mig_7series_0

  # BUG-052: device_temp_i (12 Р В±Р С‘РЎвЂљ) РІР‚вЂќ MIG XADC_En=Off, Р С—Р С‘Р Р… Р Р…Р Вµ Р С—Р С•Р Т‘Р С”Р В»РЎР‹РЎвЂЎРЎвЂР Р….
  # Р С™Р С•Р Р…РЎРѓРЎвЂљР В°Р Р…РЎвЂљРЎС“ РЎРѓР С•Р В·Р Т‘Р В°РЎвЂР С Р вЂ”Р вЂќР вЂўР РЋР В¬ (Р Т‘Р С• validate Р Р† РЎРЊРЎвЂљР С•Р С РЎРѓР С”РЎР‚Р С‘Р С—РЎвЂљР Вµ), Р С‘Р Р…Р В°РЎвЂЎР Вµ BD 41-759.
  set const_device_temp [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_device_temp]
  set_property -dict [list CONFIG.CONST_WIDTH {12} CONFIG.CONST_VAL {0}] $const_device_temp
  connect_bd_net [get_bd_pins $const_device_temp/dout] [get_bd_pins mig_7series_0/device_temp_i]

  set rst_mig_7series_0_100M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_mig_7series_0_100M ]

  # BUG-034: РЎРѓР В±РЎР‚Р С•РЎРѓ fabric-Р Т‘Р С•Р СР ВµР Р…Р В° 125 Р СљР вЂњРЎвЂ  (РЎРЏР Т‘РЎР‚Р С•/RP/Р С—Р ВµРЎР‚Р С‘РЎвЂћР ВµРЎР‚Р С‘РЎРЏ).
  # ext_reset = Р С—Р В»Р В°РЎвЂљР Р…РЎвЂ№Р в„– reset_rtl_0 (Р В°Р С”РЎвЂљР С‘Р Р†Р Р…РЎвЂ№Р в„– Р Р…Р С‘Р В·Р С”Р С‘Р в„–, Р С—Р С•Р В»РЎРЏРЎР‚Р Р…Р С•РЎРѓРЎвЂљРЎРЉ Р С—Р С• РЎС“Р СР С•Р В»РЎвЂЎР В°Р Р…Р С‘РЎР‹
  # ACTIVE_LOW РЎРѓР С•Р С•РЎвЂљР Р†Р ВµРЎвЂљРЎРѓРЎвЂљР Р†РЎС“Р ВµРЎвЂљ), locked = Р С”Р В»Р С•Р С”-wizard 125 Р СљР вЂњРЎвЂ .
  set rst_core_125M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_core_125M ]

  set util_ds_buf [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf ]
  set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $util_ds_buf

  set xdma_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.2 xdma_0 ]
  # BUG-051: XDMA 64-Р В±Р С‘РЎвЂљ @ 250 Р СљР вЂњРЎвЂ  Р СњР вЂў Р В·Р В°Р С”РЎР‚РЎвЂ№Р Р†Р В°Р ВµРЎвЂљ РЎвЂљР В°Р в„–Р СР С‘Р Р…Р С– Р Р…Р В° Artix-7
  # (Р Р†Р Р…РЎС“РЎвЂљРЎР‚Р ВµР Р…Р Р…Р С‘Р в„– userclk1 dsc_eng/dma_pcie_rc: WNS=-2.2ns, 13375 endpoints).
  # AMD community: "design simply cannot run at 250 MHz in Artix-7".
  # Р В Р ВµРЎв‚¬Р ВµР Р…Р С‘Р Вµ: 128-Р В±Р С‘РЎвЂљ @ 125 Р СљР вЂњРЎвЂ  РІР‚вЂќ РЎвЂљР В° Р В¶Р Вµ Р С—Р С•Р В»Р С•РЎРѓР В° 16BР“вЂ”125Р Сљ = 2.0 Р вЂњР вЂ/РЎРѓ,
  # userclk1 = 125 Р СљР вЂњРЎвЂ  РІР‚вЂќ РЎвЂљР В°Р в„–Р СР С‘Р Р…Р С– Р В·Р В°Р С”РЎР‚РЎвЂ№Р Р†Р В°Р ВµРЎвЂљРЎРѓРЎРЏ РЎв‚¬РЎвЂљР В°РЎвЂљР Р…Р С•.
  # Р С™Р В°Р Р…Р В°Р В»РЎвЂ№ DMA 2+2 Р РЋР С›Р ТђР В Р С’Р СњР вЂўР СњР В«. Р СџР ВµРЎР‚Р С‘РЎвЂћР ВµРЎР‚Р С‘РЎРЏ/РЎРЏР Т‘РЎР‚Р С•/RP РІР‚вЂќ Р Т‘Р С•Р СР ВµР Р… 125 Р СљР вЂњРЎвЂ .
  set_property -dict [list \
    CONFIG.PF0_DEVICE_ID_mqdma {9024} \
    CONFIG.PF0_SRIOV_VF_DEVICE_ID {A034} \
    CONFIG.PF2_DEVICE_ID_mqdma {9224} \
    CONFIG.PF3_DEVICE_ID_mqdma {9324} \
    CONFIG.axi_data_width {128_bit} \
    CONFIG.axilite_master_en {true} \
    CONFIG.axisten_freq {125} \
    CONFIG.cfg_mgmt_if {false} \
    CONFIG.pciebar2axibar_axil_master {0x40000000} \
    CONFIG.pf0_Use_Class_Code_Lookup_Assistant {true} \
    CONFIG.pf0_base_class_menu {Memory_controller} \
    CONFIG.pf0_device_id {7024} \
    CONFIG.pf0_interrupt_pin {NONE} \
    CONFIG.pf0_msix_cap_pba_bir {BAR_3:2} \
    CONFIG.pf0_msix_cap_pba_offset {00008FE0} \
    CONFIG.pf0_msix_cap_table_bir {BAR_3:2} \
    CONFIG.pf0_msix_cap_table_offset {00008000} \
    CONFIG.pf0_msix_cap_table_size {01F} \
    CONFIG.pf0_msix_enabled {true} \
    CONFIG.pf0_sub_class_interface_menu {Other_memory_controller} \
    CONFIG.pl_link_cap_max_link_speed {5.0_GT/s} \
    CONFIG.pl_link_cap_max_link_width {X4} \
    CONFIG.plltype {QPLL1} \
    CONFIG.runbit_fix {false} \
    CONFIG.xdma_axi_intf_mm {AXI_Memory_Mapped} \
    CONFIG.xdma_axilite_slave {false} \
    CONFIG.xdma_pcie_64bit_en {true} \
    CONFIG.xdma_rnum_chnl {2} \
    CONFIG.xdma_wnum_chnl {2} \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {128} \
    CONFIG.axilite_master_size {128} \
    CONFIG.mode_selection {Advanced} \
    CONFIG.Shared_Logic_Both_7xG2 {true} \
    CONFIG.Shared_Logic_Clk_7xG2 {false} \
    CONFIG.Shared_Logic_Gtc_7xG2 {false} \
  ] $xdma_0

  set clk200_clk_wiz [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk200_clk_wiz ]
set_property -dict [list \
    CONFIG.CLKOUT1_JITTER {142.107} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F {5.000} \
    CONFIG.PRIM_IN_FREQ {50.000} \
    CONFIG.MMCM_CLKIN1_PERIOD {20.000} \
    CONFIG.USE_RESET {true} \
    CONFIG.RESET_TYPE {ACTIVE_LOW} \
  ] $clk200_clk_wiz

  # BUG-034: Р С•РЎвЂљР Т‘Р ВµР В»РЎРЉР Р…РЎвЂ№Р в„– Р Т‘Р С•Р СР ВµР Р… 125 Р СљР вЂњРЎвЂ  Р Т‘Р В»РЎРЏ fabric/РЎРЏР Т‘РЎР‚Р В°/RP.
  # Р СџРЎР‚Р С‘ XDMA 64-Р В±Р С‘РЎвЂљ axi_aclk = 250 Р СљР вЂњРЎвЂ ; РЎвЂљР ВµРЎР‚Р Р…Р В°РЎР‚Р Р…Р С•Р Вµ РЎРЏР Т‘РЎР‚Р С• Р С‘ RP DataMover 128-Р В±Р С‘РЎвЂљ
  # Р В·Р В°Р С”РЎР‚РЎвЂ№Р Р†Р В°РЎР‹РЎвЂљ РЎвЂљР В°Р в„–Р СР С‘Р Р…Р С– РЎвЂљР С•Р В»РЎРЉР С”Р С• Р С—РЎР‚Р С‘ 125 Р СљР вЂњРЎвЂ  (WNS 0.370 Р Р…РЎРѓ @ 125 Р СљР вЂњРЎвЂ ).
  # 50 Р СљР вЂњРЎвЂ  Р“вЂ” 20 = VCO 1000 Р СљР вЂњРЎвЂ , /8 = 125 Р СљР вЂњРЎвЂ  (IP РЎРѓР В°Р С РЎРѓРЎвЂЎР С‘РЎвЂљР В°Р ВµРЎвЂљ Р Т‘Р ВµР В»Р С‘РЎвЂљР ВµР В»Р С‘).
  set clk125_core_wiz [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk125_core_wiz ]
set_property -dict [list \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {125.000} \
    CONFIG.PRIM_IN_FREQ {50.000} \
    CONFIG.MMCM_CLKIN1_PERIOD {20.000} \
    CONFIG.USE_RESET {true} \
    CONFIG.RESET_TYPE {ACTIVE_LOW} \
  ] $clk125_core_wiz

  set xdma_axi_smc [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 xdma_axi_smc ]
  # 3 Р Т‘Р С•Р СР ВµР Р…Р В°, 3 SI, 1 MI РІР‚вЂќ Р РЋР В Р С’Р вЂ”Р Р€ РЎвЂћР С‘Р Р…Р В°Р В»РЎРЉР Р…РЎвЂ№Р Вµ Р В·Р Р…Р В°РЎвЂЎР ВµР Р…Р С‘РЎРЏ (S02 Р В±РЎС“Р Т‘Р ВµРЎвЂљ Р С—Р С•Р Т‘Р С”Р В»РЎР‹РЎвЂЎРЎвЂР Р… Р Р† post_bd_dfx).
  # BUG-035: Р СњР вЂў РЎРѓРЎвЂљР В°Р Р†Р С‘Р С ASSOCIATED_BUSIF/FREQ_HZ Р Р…Р В° clock-Р С—Р С‘Р Р…Р В°РЎвЂ¦ РІР‚вЂќ read-only (BD 41-737)
  # Р С‘ Р В»Р С•Р СР В°РЎР‹РЎвЂљ Р В°Р Р†РЎвЂљР С•-Р Р†РЎвЂ№Р Р†Р С•Р Т‘ Р Т‘Р С•Р СР ВµР Р…Р С•Р Р†. Vivado РЎРѓР В°Р С Р Р†РЎвЂ№Р Р†Р С•Р Т‘Р С‘РЎвЂљ Р Т‘Р С•Р СР ВµР Р…РЎвЂ№ Р С‘Р В· FREQ_HZ Р С—Р С•РЎР‚РЎвЂљР С•Р Р†/IP.
  set_property -dict [list \
    CONFIG.NUM_CLKS {3} \
    CONFIG.NUM_SI {3} \
    CONFIG.NUM_MI {1} \
  ] $xdma_axi_smc

  set xdma_axi_lite_smc [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 xdma_axi_lite_smc ]
  # 2 Р Т‘Р С•Р СР ВµР Р…Р В°, 6 MI Р РЋР В Р С’Р вЂ”Р Р€ (M03-M05 Р В±РЎС“Р Т‘РЎС“РЎвЂљ Р С—Р С•Р Т‘Р С”Р В»РЎР‹РЎвЂЎР ВµР Р…РЎвЂ№ Р Р† post_bd_dfx).
  set_property -dict [list \
    CONFIG.NUM_MI {7} \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_CLKS {2} \
  ] $xdma_axi_lite_smc

  set mig7_status_concat [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 mig7_status_concat ]

  connect_bd_intf_net -intf_net axi_gpio_0_GPIO [get_bd_intf_ports gpio_rtl_0] [get_bd_intf_pins axi_gpio_0/GPIO]
  connect_bd_intf_net -intf_net dfx_partition_rp_M_AXI [get_bd_intf_pins dfx_partition/rp_M_AXI] [get_bd_intf_pins dfx_socket/rp_M_AXI]
  connect_bd_intf_net -intf_net dfx_socket_M_AXI [get_bd_intf_pins dfx_socket/M_AXI] [get_bd_intf_pins xdma_axi_smc/S01_AXI]
  connect_bd_intf_net -intf_net diff_clock_rtl_0_1 [get_bd_intf_ports diff_clock_rtl_0] [get_bd_intf_pins util_ds_buf/CLK_IN_D]
  connect_bd_intf_net -intf_net mig_7series_0_DDR3 [get_bd_intf_ports DDR3_0] [get_bd_intf_pins mig_7series_0/DDR3]
  connect_bd_intf_net -intf_net rp_S_AXI_1 [get_bd_intf_pins dfx_partition/rp_S_AXI] [get_bd_intf_pins dfx_socket/rp_S_AXI]
  connect_bd_intf_net -intf_net xdma_0_M_AXI [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins xdma_axi_smc/S00_AXI]
  connect_bd_intf_net -intf_net xdma_0_M_AXI_LITE [get_bd_intf_pins xdma_0/M_AXI_LITE] [get_bd_intf_pins xdma_axi_lite_smc/S00_AXI]
  connect_bd_intf_net -intf_net xdma_0_pcie_mgt [get_bd_intf_ports pcie_7x_mgt_rtl_0] [get_bd_intf_pins xdma_0/pcie_mgt]
  connect_bd_intf_net -intf_net xdma_axi_lite_smc_M00_AXI [get_bd_intf_pins xdma_axi_lite_smc/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
  connect_bd_intf_net -intf_net xdma_axi_lite_smc_M01_AXI [get_bd_intf_pins xdma_axi_lite_smc/M01_AXI] [get_bd_intf_pins dfx_socket/S_AXI]
  connect_bd_intf_net -intf_net xdma_axi_smc_M00_AXI [get_bd_intf_pins xdma_axi_smc/M00_AXI] [get_bd_intf_pins mig_7series_0/S_AXI]

  # ============================================================================
  # DIAG (2026-10-03): BRAM-РѕР±С…РѕРґ РґР»СЏ TDOT + DMA вЂ” Р»РѕРєР°Р»СЊРЅС‹Р№ 8 РљР‘ SRAM,
  # РґРѕСЃС‚СѓРїРЅС‹Р№ Рё TDOT-РјР°СЃС‚РµСЂСѓ, Рё XDMA-РјР°СЃС‚РµСЂСѓ РїРѕ Р°РґСЂРµСЃСѓ 0x00000000 (РІ РѕР±С…РѕРґ DDR3).
  # РџРѕР·РІРѕР»СЏРµС‚ РїСЂРѕРІРµСЂРёС‚СЊ СЏРґСЂРѕ Рё DMA-РїСѓС‚СЊ Р‘Р•Р— РґРѕСЃС‚СѓРїР° Рє РЅРµРёРЅРёС†РёР°Р»РёР·РёСЂРѕРІР°РЅРЅРѕРјСѓ MIG.
  # ============================================================================
  # DIAG BRAM (BRAM-РѕР±С…РѕРґ РґР»СЏ TDOT + DMA): РћР”РРќ РїРѕСЂС‚ S_AXI (INTERNAL).
  #
  # Р РђР—Р‘РћР  РџР Р•Р”Р«Р”РЈР©Р•Р™ РћРЁРР‘РљР СЃР±РѕСЂРєРё (vivado.log, BD 5-216):
  #   "VLNV <xilinx.com:ip:blk_mem_gen:8.3> is not supported for the current
  #    part. The latest supported version for this part is: <8.4>"
  # Р СѓС‡РЅРѕР№ blk_mem_gen 8.3 РЅРµ РїРѕРґРґРµСЂР¶РёРІР°РµС‚СЃСЏ РЅР° xc7a200t РІ Vivado 2025.2.
  # Р РµС€РµРЅРёРµ: РќР• СЃРѕР·РґР°С‘Рј blk_mem_gen РІСЂСѓС‡РЅСѓСЋ. axi_bram_ctrl РІ СЂРµР¶РёРјРµ
  # BRAM_INST_MODE=INTERNAL(РїРѕ СѓРјРѕР»С‡.) РЎРђРњ РіРµРЅРµСЂРёСЂСѓРµС‚ РІРЅСѓС‚СЂРµРЅРЅРёР№ blk_mem_gen
  # РєРѕСЂСЂРµРєС‚РЅРѕР№ РІРµСЂСЃРёРё, Р° РЅР°СЂСѓР¶Сѓ РІС‹РґР°С‘С‚ С‚РѕР»СЊРєРѕ AXI-РїРѕСЂС‚ S_AXI вЂ” Рё РѕС‚РґРµР»СЊРЅРѕРіРѕ
  # РІРЅРµС€РЅРµРіРѕ BRAM РЅРµ С‚СЂРµР±СѓРµС‚СЃСЏ, Рё РѕС€РёР±РєРё 8.3/8.4 РЅРµ РІРѕР·РЅРёРєР°РµС‚.
  #
  # Р’Р°Р¶РЅРѕ РїСЂРѕ РїРѕСЂС‚ B: axi_bram_ctrl v4.1 РЅРµ РїРѕРґРґРµСЂР¶РёРІР°РµС‚ Р РђР—РќР«Р• РїСЂРѕС‚РѕРєРѕР»С‹ РЅР°
  # S_AXI Рё S_AXI_B (РѕР±Р° РѕРґРЅРёРј C_S_AXI_PROTOCOL=AXI4). РҐРѕСЃС‚ (AXI-Lite M02 РёР·
  # xdma_axi_lite_smc) Рє AXI4-РїРѕСЂС‚Сѓ B РїРѕРґРєР»СЋС‡РёС‚СЊ РЅРµР»СЊР·СЏ. РџРѕСЌС‚РѕРјСѓ РёСЃРїРѕР»СЊР·СѓРµРј
  # РћР”РРќ РїРѕСЂС‚ S_AXI (AXI4): Рё XDMA M_AXI, Рё TDOT-РјР°СЃС‚РµСЂ РёРґСѓС‚ С‡РµСЂРµР·
  # xdma_axi_smc в†’ M01 в†’ S_AXI. РҐРѕСЃС‚ РїРёС€РµС‚/С‡РёС‚Р°РµС‚ BRAM С‡РµСЂРµР· S00 (XDMA M_AXI)
  # РѕР±С‹С‡РЅС‹Рј DMA С…РѕСЃС‚->0x00000000 (BRAM) вЂ” СЌС‚Рѕ Рё РµСЃС‚СЊ РѕР±С…РѕРґРЅРѕР№ С‚РµСЃС‚ Р±РµР· DDR3.
  # ============================================================================
  set diag_bram [ create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 diag_bram ]
  set_property -dict [list \
    CONFIG.Memory_Type {Single_Port_RAM} \
    CONFIG.Write_Width_A {64} \
    CONFIG.Write_Depth_A {1024} \
    CONFIG.Read_Width_A {64} \
    CONFIG.use_bram_block {Stand_Alone} \
  ] $diag_bram

  set diag_bram_ctrl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 diag_bram_ctrl ]
  set_property -dict [list \
    CONFIG.DATA_WIDTH {64} \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.SINGLE_PORT_BRAM {1} \
  ] $diag_bram_ctrl

  # AXI BRAM Controller РІ EXTERNAL С‚СЂРµР±СѓРµС‚ Р’РќР•РЁРќРР™
  # blk_mem_gen РЅР° BRAM_PORTA (РѕРґРёРЅ РїРѕСЂС‚ S_AXI). РџРѕРґРєР»СЋС‡Р°РµРј.
  connect_bd_intf_net [get_bd_intf_pins diag_bram_ctrl/BRAM_PORTA] [get_bd_intf_pins diag_bram/BRAM_PORTA]

  # FIX-MT 2026-10-04: blk_mem_gen Stand_Alone exposes rsta_busy (BRAM reset-busy) which
  # was previously left dangling in BRAM_Controller/EXTERNAL mode. Tie it to an exported
  # top-level port so it is not "in the air" (no unconnected-pin DRC) and the diag BRAM
  # actually implements memory.
  if {[get_bd_pins -quiet diag_bram/rsta_busy] ne ""} {
      if {[get_bd_ports -quiet diag_rst_busy] eq ""} {
          create_bd_port -dir O -from 0 -to 0 diag_rst_busy
      }
      connect_bd_net [get_bd_pins diag_bram/rsta_busy] [get_bd_ports diag_rst_busy]
      puts " diag_bram: rsta_busy -> diag_rst_busy (tied, not dangling)"
  }

  # --- (РЁР°Рі A1) xdma_axi_smc: РґРѕР±Р°РІРёС‚СЊ M01 -> diag_bram_ctrl/S_AXI ---
  set_property -dict [list CONFIG.NUM_MI {2}] $xdma_axi_smc
  connect_bd_intf_net -intf_net xdma_axi_smc_M01_AXI [get_bd_intf_pins xdma_axi_smc/M01_AXI] [get_bd_intf_pins diag_bram_ctrl/S_AXI]

  # --- (РЁР°Рі B) РґРѕСЃС‚СѓРї С…РѕСЃС‚Р° Рє BRAM ---
  # РҐРѕСЃС‚ РїРёС€РµС‚/С‡РёС‚Р°РµС‚ BRAM С‡РµСЂРµР· S00 (XDMA M_AXI в†’ xdma_axi_smc в†’ M01 в†’ S_AXI),
  # РѕР±С‹С‡РЅС‹Рј DMA РЅР° Р°РґСЂРµСЃ 0x00000000 (8 РљР‘). AXI-Lite РїРѕСЂС‚ B РЅРµ РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ
  # (axi_bram_ctrl v4.1 РЅРµ РґР°С‘С‚ СЂР°Р·РЅС‹С… РїСЂРѕС‚РѕРєРѕР»РѕРІ A/B; SINGLE_PORT=true).

  connect_bd_net -net clk200_clk_wiz_clk_out1 [get_bd_pins clk200_clk_wiz/clk_out1] \
  [get_bd_pins mig_7series_0/clk_ref_i] \
  [get_bd_pins mig_7series_0/sys_clk_i]

  connect_bd_net -net clk50_buf_IBUF_OUT [get_bd_ports clk50] \
  [get_bd_pins clk200_clk_wiz/clk_in1] \
  [get_bd_pins clk125_core_wiz/clk_in1]

  # fabric/core domain 125 MHz (BUG-034): dfx_socket, dfx_partition (RP),
  # GPIO, M-side of xdma_axi_lite_smc, S01/S02 sides of
  # xdma_axi_smc (S02 added by post_bd_dfx). Static rate 125 MHz.
  connect_bd_net -net clk125_core_wiz_clk_out1 [get_bd_pins clk125_core_wiz/clk_out1] \
  [get_bd_pins dfx_socket/clk] \
  [get_bd_pins dfx_partition/clk] \
  [get_bd_pins axi_gpio_0/s_axi_aclk] \
  [get_bd_pins xdma_axi_lite_smc/aclk1] \
  [get_bd_pins xdma_axi_smc/aclk2] \
  [get_bd_pins rst_core_125M/slowest_sync_clk]

  connect_bd_net -net clk125_core_wiz_locked [get_bd_pins clk125_core_wiz/locked] \
  [get_bd_pins rst_core_125M/dcm_locked]

  connect_bd_net -net mig7_status_concat_dout [get_bd_pins mig7_status_concat/dout] \
  [get_bd_pins axi_gpio_0/gpio2_io_i]

  connect_bd_net -net mig_7series_0_init_calib_complete [get_bd_pins mig_7series_0/init_calib_complete] \
  [get_bd_pins mig7_status_concat/In1]

  connect_bd_net -net mig_7series_0_mmcm_locked [get_bd_pins mig_7series_0/mmcm_locked] \
  [get_bd_pins rst_mig_7series_0_100M/dcm_locked] \
  [get_bd_pins mig7_status_concat/In0]

  connect_bd_net -net mig_7series_0_ui_clk [get_bd_pins mig_7series_0/ui_clk] \
  [get_bd_pins rst_mig_7series_0_100M/slowest_sync_clk] \
  [get_bd_pins xdma_axi_smc/aclk1]

  connect_bd_net -net mig_7series_0_ui_clk_sync_rst [get_bd_pins mig_7series_0/ui_clk_sync_rst] \
  [get_bd_pins rst_mig_7series_0_100M/ext_reset_in]

  connect_bd_net -net reset_rtl_0_1 [get_bd_ports reset_rtl_0] \
  [get_bd_pins xdma_0/sys_rst_n] \
  [get_bd_pins mig_7series_0/sys_rst] \
  [get_bd_pins clk200_clk_wiz/resetn] \
  [get_bd_pins clk125_core_wiz/resetn] \
  [get_bd_pins rst_core_125M/ext_reset_in]

  connect_bd_net -net rp_resetn_1 [get_bd_pins dfx_socket/rp_resetn] \
  [get_bd_pins dfx_partition/rp_resetn]

  connect_bd_net -net rst_mig_7series_0_100M_peripheral_aresetn [get_bd_pins rst_mig_7series_0_100M/peripheral_aresetn] \
  [get_bd_pins mig_7series_0/aresetn]

  connect_bd_net -net rst_core_125M_peripheral_aresetn [get_bd_pins rst_core_125M/peripheral_aresetn] \
  [get_bd_pins dfx_socket/resetn] \
  [get_bd_pins axi_gpio_0/s_axi_aresetn]

  connect_bd_net -net util_ds_buf_IBUF_OUT [get_bd_pins util_ds_buf/IBUF_OUT] \
  [get_bd_pins xdma_0/sys_clk]

  # PCIe-Р Т‘Р С•Р СР ВµР Р… XDMA (250 Р СљР вЂњРЎвЂ  Р С—РЎР‚Р С‘ 64-Р В±Р С‘РЎвЂљ, BUG-034): РЎвЂљР С•Р В»РЎРЉР С”Р С• XDMA Р С‘
  # S-РЎРѓРЎвЂљР С•РЎР‚Р С•Р Р…РЎвЂ№ SmartConnect. Р СџР ВµРЎР‚Р С‘РЎвЂћР ВµРЎР‚Р С‘РЎРЏ/РЎРЏР Т‘РЎР‚Р С•/RP РІР‚вЂќ Р Р† Р Т‘Р С•Р СР ВµР Р…Р Вµ clk125_core_wiz.
connect_bd_net -net xdma_0_axi_aclk [get_bd_pins xdma_0/axi_aclk] \
  [get_bd_pins xdma_axi_lite_smc/aclk] \
  [get_bd_pins xdma_axi_smc/aclk] \
  [get_bd_pins diag_bram_ctrl/s_axi_aclk]

connect_bd_net -net xdma_0_axi_aresetn [get_bd_pins xdma_0/axi_aresetn] \
  [get_bd_pins xdma_axi_lite_smc/aresetn] \
  [get_bd_pins xdma_axi_smc/aresetn] \
  [get_bd_pins diag_bram_ctrl/s_axi_aresetn]

  assign_bd_address -offset 0x00000000 -range 0x10000000 -target_address_space [get_bd_addr_spaces dfx_partition/axi_datamover_0/Data_MM2S] [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
  assign_bd_address -offset 0x00000000 -range 0x10000000 -target_address_space [get_bd_addr_spaces dfx_partition/axi_datamover_1/Data_S2MM] [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
  assign_bd_address -offset 0x80000000 -range 0x10000000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI] [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
  assign_bd_address -offset 0x40010000 -range 0x00001000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs dfx_partition/axi_datamover_mm2s_c_0/s_axi/reg0] -force
  assign_bd_address -offset 0x40018000 -range 0x00001000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs dfx_partition/axi_datamover_s2mm_c_0/s_axi/reg0] -force
assign_bd_address -offset 0x40020000 -range 0x00001000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force
assign_bd_address -offset 0x40022000 -range 0x00001000 -with_name SEG_axi_gpio_0_Reg_2 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs dfx_socket/decouple_shutdown_ctrl/S_AXI/Reg] -force

  # ---- DIAG (2026-10-03): Р°РґСЂРµСЃРЅС‹Рµ РєР°СЂС‚С‹ BRAM-РѕР±С…РѕРґР° ----
  # (A) XDMA-РјР°СЃС‚РµСЂ РїРѕР»СѓС‡Р°РµС‚ СЃРµРіРјРµРЅС‚ BRAM 0x00000000 (8 РљР‘) Р’ Р”РћР‘РђР’Р›Р•РќРР• Рє
  #     DDR3 0x80000000. (assign РґР»СЏ tdot_m_port вЂ” РЅРёР¶Рµ, РїРѕСЃР»Рµ РµРіРѕ СЃРѕР·РґР°РЅРёСЏ.)
  assign_bd_address -offset 0x10000000 -range 0x00002000 \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI] \
    [get_bd_addr_segs diag_bram_ctrl/S_AXI/Mem0] -force
  # (B) РҐРѕСЃС‚ РїРёС€РµС‚/С‡РёС‚Р°РµС‚ BRAM С‡РµСЂРµР· XDMA M_AXI (S00) РїРѕ 0x00000000 (8 РљР‘) вЂ” DMA.
  # AXI-Lite РїРѕСЂС‚ РЅРµ РЅСѓР¶РµРЅ (SINGLE_PORT); Р°РґСЂРµСЃ 0x40006000 РЅРµ РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ.

  current_bd_instance $oldCurInst

  # ============================================================================
  # Р РЋР С•Р В·Р Т‘Р В°Р Р…Р С‘Р Вµ Р Р†Р Р…Р ВµРЎв‚¬Р Р…Р С‘РЎвЂ¦ Р С—Р С•РЎР‚РЎвЂљР С•Р Р† (Р В±РЎвЂ№Р Р†РЎв‚¬Р С‘Р в„– post_bd_dfx РЎв‚¬Р В°Р С–Р С‘ 1-4)
  # Р вЂќР ВµР В»Р В°Р ВµР С Р вЂ”Р вЂќР вЂўР РЋР В¬ Р Т‘Р С• validate_bd_design, РЎвЂЎРЎвЂљР С•Р В±РЎвЂ№ Vivado Р Р†Р С‘Р Т‘Р ВµР В» FREQ_HZ=125 Р Р…Р В° Р С—Р С•РЎР‚РЎвЂљР В°РЎвЂ¦
  # Р С‘ Р В°Р Р†РЎвЂљР С•-Р Р†РЎвЂ№Р Р†Р ВµР В» Р Т‘Р С•Р СР ВµР Р… fabric (125 Р СљР вЂњРЎвЂ ) Р Т‘Р В»РЎРЏ S02/M03-M05 (BUG-035).
  # ============================================================================

  # M_AXI_TDOT РІР‚вЂќ AXI4 master Р С•РЎвЂљ tdot_axi4 Р С” DDR3
  set tdot_m_port [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_TDOT]
  set_property -dict [list \
    CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 64 CONFIG.ADDR_WIDTH 32 \
    CONFIG.NUM_READ_OUTSTANDING 2 CONFIG.NUM_WRITE_OUTSTANDING 2 CONFIG.FREQ_HZ 125000000] $tdot_m_port
  connect_bd_intf_net [get_bd_intf_pins xdma_axi_smc/S02_AXI] $tdot_m_port
  assign_bd_address -offset 0x80000000 -range 0x10000000 \
    -target_address_space [get_bd_addr_spaces $tdot_m_port] \
    [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
  # DIAG: TDOT-РјР°СЃС‚РµСЂ С‚Р°РєР¶Рµ РІРёРґРёС‚ BRAM 0x00000000 (8 РљР‘) вЂ” РѕР±С…РѕРґ DDR3.
  assign_bd_address -offset 0x10000000 -range 0x00002000 \
    -target_address_space [get_bd_addr_spaces $tdot_m_port] \
    [get_bd_addr_segs diag_bram_ctrl/S_AXI/Mem0] -force

  # S_AXI_TDOT_REGS
  set tdot_port [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_TDOT_REGS]
  set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 8 CONFIG.FREQ_HZ 125000000] $tdot_port
  connect_bd_intf_net [get_bd_intf_pins xdma_axi_lite_smc/M03_AXI] $tdot_port
  assign_bd_address -offset 0x40023000 -range 0x1000 \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs $tdot_port/Reg] -force

  # (ICAP/SPI порты убраны 2026-10-05: RTL-top не инстанцирует icap_ctrl/spi_over_pcie;
  #  адреса 0x40024000/0x40025000 больше не выделяются и не входят в ADDRESS_MAP §2.)

  # S_AXI_XADC_REGS
  set xadc_port [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_XADC_REGS]
  set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 8 CONFIG.FREQ_HZ 125000000] $xadc_port
  connect_bd_intf_net [get_bd_intf_pins xdma_axi_lite_smc/M05_AXI] $xadc_port
  assign_bd_address -offset 0x46000000 -range 0x1000 \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs $xadc_port/Reg] -force

  # (SPI-порт убран 2026-10-05 — RTL не инстанцирует spi_over_pcie, см. ICAP выше.)

  # ---- BUG-035: Р С—РЎР‚Р С‘Р Р†РЎРЏР В·Р С”Р В° Р Р†Р Р…Р ВµРЎв‚¬Р Р…Р С‘РЎвЂ¦ Р С—Р С•РЎР‚РЎвЂљР С•Р Р† Р С” fabric-Р Т‘Р С•Р СР ВµР Р…РЎС“ 125 Р СљР вЂњРЎвЂ  ----
  # Vivado Р Р…Р Вµ Р В°Р Р†РЎвЂљР С•-Р Р†РЎвЂ№Р Р†Р С•Р Т‘Р С‘РЎвЂљ Р Т‘Р С•Р СР ВµР Р… Р Т‘Р В»РЎРЏ Р Р†Р Р…Р ВµРЎв‚¬Р Р…Р С‘РЎвЂ¦ AXI-Р С—Р С•РЎР‚РЎвЂљР С•Р Р† РІР‚вЂќ Р С•Р Р…Р С‘ РЎРѓР В°Р Т‘РЎРЏРЎвЂљРЎРѓРЎРЏ Р Р…Р В°
  # aclk=250 РІвЂ вЂ™ BD 41-237 (FREQ_HZ mismatch 250 vs 125). Р В Р ВµРЎв‚¬Р ВµР Р…Р С‘Р Вµ (probe3 V5):
  # Р В°РЎРѓРЎРѓР С•РЎвЂ Р С‘Р С‘РЎР‚Р С•Р Р†Р В°РЎвЂљРЎРЉ Р С‘Р СР ВµР Р…Р В° Р Р†Р Р…Р ВµРЎв‚¬Р Р…Р С‘РЎвЂ¦ Р С—Р С•РЎР‚РЎвЂљР С•Р Р† РЎРѓ РЎРЊР С”РЎРѓР С—Р С•РЎР‚РЎвЂљР С‘РЎР‚Р С•Р Р†Р В°Р Р…Р Р…РЎвЂ№Р С Р С”Р В»Р С•Р С”-Р С—Р С•РЎР‚РЎвЂљР С•Р С
  # clk_core_out (125 Р СљР вЂњРЎвЂ , Р С—Р С‘РЎвЂљР В°Р ВµРЎвЂљ РЎвЂљР С•РЎвЂљ Р В¶Р Вµ Р Т‘Р С•Р СР ВµР Р…, РЎвЂЎРЎвЂљР С• aclk2/aclk1).
  if {[get_bd_ports -quiet clk_core_out] eq ""} {
      create_bd_port -dir O -type clk -freq_hz 125000000 clk_core_out
  }
  # BUG-035: Р С—РЎР‚Р С‘Р Р†РЎРЏР В·Р С”Р В° Р Р†Р Р…Р ВµРЎв‚¬Р Р…Р С‘РЎвЂ¦ Р С—Р С•РЎР‚РЎвЂљР С•Р Р† Р С” fabric-Р Т‘Р С•Р СР ВµР Р…РЎС“ 125 Р СљР вЂњРЎвЂ .
  # Р вЂ™Р С’Р вЂ“Р СњР С›: РЎР‚Р В°Р В·Р Т‘Р ВµР В»Р С‘РЎвЂљР ВµР В»РЎРЉ Р Р† ASSOCIATED_BUSIF РІР‚вЂќ Р вЂќР вЂ™Р С›Р вЂўР СћР С›Р В§Р ВР вЂў (Р С”Р В°Р С” Р Р† default.tcl
  # {rp_M_AXI:rp_S_AXI}), Р СњР вЂў Р С—РЎР‚Р С•Р В±Р ВµР В»! Р РЋ Р С—РЎР‚Р С•Р В±Р ВµР В»Р В°Р СР С‘ Vivado Р С‘РЎвЂ°Р ВµРЎвЂљ Р С‘Р Р…РЎвЂљР ВµРЎР‚РЎвЂћР ВµР в„–РЎРѓ
  # РЎРѓ Р С•Р Т‘Р Р…Р С‘Р С Р С‘Р СР ВµР Р…Р ВµР С "<a> <b>" РІвЂ вЂ™ BD 41-1287 "not found".
  # Р ВР СР ВµР Р…Р В° РІР‚вЂќ Р Р†Р Р…Р ВµРЎв‚¬Р Р…Р С‘РЎвЂ¦ BD-Р С—Р С•РЎР‚РЎвЂљР С•Р Р† (M_AXI_TDOT...), Р С•Р Р…Р С‘ Р С—РЎР‚Р С•Р Р†Р ВµРЎР‚Р ВµР Р…РЎвЂ№ Р Р† diag8: VALIDATE OK.
  if {[get_bd_ports -quiet clk_core_out] eq ""} {
      create_bd_port -dir O -type clk -freq_hz 125000000 clk_core_out
  }
  # Р ВР Т‘Р ВµР СР С—Р С•РЎвЂљР ВµР Р…РЎвЂљР Р…Р С•: Р С—Р С•Р Т‘Р С”Р В»РЎР‹РЎвЂЎР В°Р ВµР С clk_core_out РЎвЂљР С•Р В»РЎРЉР С”Р С• Р ВµРЎРѓР В»Р С‘ Р С•Р Р… Р ВµРЎвЂ°РЎвЂ Р Р…Р Вµ Р Р…Р В° РЎРѓР ВµРЎвЂљР С‘
  if {[llength [get_bd_nets -quiet -of_objects [get_bd_ports clk_core_out]]] == 0} {
      set _cpin [get_bd_pins clk125_core_wiz/clk_out1]
      set _cnet [get_bd_nets -quiet -of_objects $_cpin]
      if {$_cnet eq ""} {
          connect_bd_net [get_bd_ports clk_core_out] $_cpin
      } else {
          connect_bd_net -net $_cnet [get_bd_ports clk_core_out]
      }
  }
  set_property CONFIG.ASSOCIATED_BUSIF {M_AXI_TDOT:S_AXI_TDOT_REGS:S_AXI_XADC_REGS} [get_bd_ports clk_core_out]

  validate_bd_design
  save_bd_design
}

##################################################################
# MAIN FLOW
##################################################################
create_root_design ""


-- Top level: AXI4-Lite control + AXI4-Stream FIR decimator.
-- Clocking: ONE clock domain. aclk drives the AXI4-Lite slave, both AXI4-Stream
-- ports and the datapath; aresetn is synchronous, active low. There is no CDC
-- logic. If control and data must run on different clocks, add a CDC stage
-- (for example an AXI clock converter) outside this block.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fir_pkg.all;

entity axi_fir_top is
  port (
    aclk           : in  std_logic;
    aresetn        : in  std_logic;
    s_axil_awaddr  : in  std_logic_vector(7 downto 0);
    s_axil_awvalid : in  std_logic;
    s_axil_awready : out std_logic;
    s_axil_wdata   : in  std_logic_vector(31 downto 0);
    s_axil_wstrb   : in  std_logic_vector(3 downto 0);
    s_axil_wvalid  : in  std_logic;
    s_axil_wready  : out std_logic;
    s_axil_bresp   : out std_logic_vector(1 downto 0);
    s_axil_bvalid  : out std_logic;
    s_axil_bready  : in  std_logic;
    s_axil_araddr  : in  std_logic_vector(7 downto 0);
    s_axil_arvalid : in  std_logic;
    s_axil_arready : out std_logic;
    s_axil_rdata   : out std_logic_vector(31 downto 0);
    s_axil_rresp   : out std_logic_vector(1 downto 0);
    s_axil_rvalid  : out std_logic;
    s_axil_rready  : in  std_logic;
    s_axis_tdata   : in  std_logic_vector(15 downto 0);
    s_axis_tvalid  : in  std_logic;
    s_axis_tready  : out std_logic;
    m_axis_tdata   : out std_logic_vector(15 downto 0);
    m_axis_tvalid  : out std_logic;
    m_axis_tready  : in  std_logic
  );
end entity;

architecture rtl of axi_fir_top is
  signal enable, soft_rst, ovf_event, out_event, busy : std_logic;
  signal decim : unsigned(3 downto 0);
  signal coefs : coef_array_t;
begin
  u_regs : entity work.axil_regs
    port map (
      aclk => aclk, aresetn => aresetn,
      s_axil_awaddr => s_axil_awaddr, s_axil_awvalid => s_axil_awvalid, s_axil_awready => s_axil_awready,
      s_axil_wdata => s_axil_wdata, s_axil_wstrb => s_axil_wstrb, s_axil_wvalid => s_axil_wvalid,
      s_axil_wready => s_axil_wready, s_axil_bresp => s_axil_bresp, s_axil_bvalid => s_axil_bvalid,
      s_axil_bready => s_axil_bready, s_axil_araddr => s_axil_araddr, s_axil_arvalid => s_axil_arvalid,
      s_axil_arready => s_axil_arready, s_axil_rdata => s_axil_rdata, s_axil_rresp => s_axil_rresp,
      s_axil_rvalid => s_axil_rvalid, s_axil_rready => s_axil_rready,
      enable => enable, soft_rst => soft_rst, decim => decim, coefs => coefs,
      ovf_event => ovf_event, out_event => out_event, busy => busy);

  u_fir : entity work.fir_decim
    port map (
      aclk => aclk, aresetn => aresetn, enable => enable, soft_rst => soft_rst,
      decim => decim, coefs => coefs,
      s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid, s_axis_tready => s_axis_tready,
      m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid, m_axis_tready => m_axis_tready,
      ovf_event => ovf_event, out_event => out_event, busy => busy);
end architecture;

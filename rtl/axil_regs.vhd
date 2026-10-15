-- AXI4-Lite slave register block for the FIR decimator.
-- Single clock domain (aclk), synchronous active-low reset (aresetn).
-- One outstanding transaction per channel; AW and W are accepted together.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;
use work.fir_pkg.all;

entity axil_regs is
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
    -- to/from FIR core
    enable         : out std_logic;
    soft_rst       : out std_logic;                -- one-cycle pulse
    decim          : out unsigned(3 downto 0);
    coefs          : out coef_array_t;
    ovf_event      : in  std_logic;                -- one-cycle pulse
    out_event      : in  std_logic;                -- one pulse per output handshake
    busy           : in  std_logic
  );
end entity;

architecture rtl of axil_regs is
  constant RESP_OKAY   : std_logic_vector(1 downto 0) := "00";
  constant RESP_SLVERR : std_logic_vector(1 downto 0) := "10";

  signal enable_r   : std_logic := '0';
  signal soft_rst_r : std_logic := '0';
  signal decim_r    : unsigned(3 downto 0) := to_unsigned(2, 4);
  signal coef_addr  : unsigned(4 downto 0) := (others => '0');
  signal coefs_r    : coef_array_t := (others => (others => '0'));
  signal overflow   : std_logic := '0';
  signal count      : unsigned(31 downto 0) := (others => '0');

  signal bvalid_r : std_logic := '0';
  signal bresp_r  : std_logic_vector(1 downto 0) := RESP_OKAY;
  signal rvalid_r : std_logic := '0';
  signal rresp_r  : std_logic_vector(1 downto 0) := RESP_OKAY;
  signal rdata_r  : std_logic_vector(31 downto 0) := (others => '0');

  signal wr_go, rd_go : std_logic;
begin
  -- A write is accepted when address and data are both present and no response is pending.
  wr_go <= s_axil_awvalid and s_axil_wvalid and not bvalid_r;
  rd_go <= s_axil_arvalid and not rvalid_r;

  s_axil_awready <= wr_go;
  s_axil_wready  <= wr_go;
  s_axil_bvalid  <= bvalid_r;
  s_axil_bresp   <= bresp_r;
  s_axil_arready <= rd_go;
  s_axil_rvalid  <= rvalid_r;
  s_axil_rresp   <= rresp_r;
  s_axil_rdata   <= rdata_r;

  enable   <= enable_r;
  soft_rst <= soft_rst_r;
  decim    <= decim_r;
  coefs    <= coefs_r;

  process (aclk)
    variable a       : natural;
    variable wd      : std_logic_vector(31 downto 0);
    variable ovf_clr : boolean;
  begin
    if rising_edge(aclk) then
      soft_rst_r <= '0';
      ovf_clr := false;

      -- write channel
      if bvalid_r = '1' and s_axil_bready = '1' then
        bvalid_r <= '0';
      end if;
      if wr_go = '1' then
        a  := to_integer(unsigned(s_axil_awaddr(7 downto 2))) * 4;
        wd := s_axil_wdata;  -- ponytail: wstrb ignored (full-word writes only); add byte lanes if a driver needs them
        bvalid_r <= '1';
        bresp_r  <= RESP_OKAY;
        case a is
          when ADDR_CTRL =>
            enable_r   <= wd(0);
            soft_rst_r <= wd(1);
          when ADDR_DECIM =>
            if unsigned(wd) >= 2 and unsigned(wd) <= 8 then
              decim_r <= unsigned(wd(3 downto 0));
            end if;
          when ADDR_COEF_ADDR =>
            coef_addr <= unsigned(wd(4 downto 0));
          when ADDR_COEF_DATA =>
            coefs_r(to_integer(coef_addr)) <= signed(wd(15 downto 0));
            coef_addr <= coef_addr + 1;
          when ADDR_STATUS =>
            ovf_clr := wd(0) = '1';
          when ADDR_SAMPLE_COUNT | ADDR_VERSION =>
            null;  -- read-only, write ignored with OKAY
          when others =>
            bresp_r <= RESP_SLVERR;
        end case;
      end if;

      -- read channel
      if rvalid_r = '1' and s_axil_rready = '1' then
        rvalid_r <= '0';
      end if;
      if rd_go = '1' then
        a := to_integer(unsigned(s_axil_araddr(7 downto 2))) * 4;
        rvalid_r <= '1';
        rresp_r  <= RESP_OKAY;
        rdata_r  <= (others => '0');
        case a is
          when ADDR_CTRL         => rdata_r(0) <= enable_r;
          when ADDR_DECIM        => rdata_r(3 downto 0) <= std_logic_vector(decim_r);
          when ADDR_COEF_ADDR    => rdata_r(4 downto 0) <= std_logic_vector(coef_addr);
          when ADDR_COEF_DATA    => rdata_r <= std_logic_vector(resize(coefs_r(to_integer(coef_addr)), 32));
          when ADDR_STATUS       => rdata_r(1 downto 0) <= busy & overflow;
          when ADDR_SAMPLE_COUNT => rdata_r <= std_logic_vector(count);
          when ADDR_VERSION      => rdata_r <= RST_VERSION;
          when others            => rresp_r <= RESP_SLVERR;
        end case;
      end if;

      -- status (a new overflow event wins over a clear in the same cycle)
      if soft_rst_r = '1' then
        overflow <= '0';
        count    <= (others => '0');
      else
        if ovf_clr then
          overflow <= '0';
        end if;
        if ovf_event = '1' then
          overflow <= '1';
        end if;
        if out_event = '1' then
          count <= count + 1;
        end if;
      end if;

      if aresetn = '0' then
        enable_r   <= '0';
        soft_rst_r <= '0';
        decim_r    <= unsigned(RST_DECIM(3 downto 0));
        coef_addr  <= (others => '0');
        coefs_r    <= (others => (others => '0'));
        overflow   <= '0';
        count      <= (others => '0');
        bvalid_r   <= '0';
        rvalid_r   <= '0';
      end if;
    end if;
  end process;
end architecture;

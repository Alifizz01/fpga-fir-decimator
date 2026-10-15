-- AXI4-Stream FIR decimator.
-- 32 programmable taps, Q1.15 data and coefficients, decimation R = 2..8.
--   y[m] = sat16( floor((sum_{k=0..31} h[k]*x[mR + R-1 - k] + 2^14) / 2^15) ),  x[n<0] = 0
-- One shared multiplier: after R input samples the core runs 32 MAC cycles,
-- then holds the result on m_axis until tready. s_axis_tready is low meanwhile.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fir_pkg.all;

entity fir_decim is
  port (
    aclk          : in  std_logic;
    aresetn       : in  std_logic;
    enable        : in  std_logic;
    soft_rst      : in  std_logic;
    decim         : in  unsigned(3 downto 0);
    coefs         : in  coef_array_t;
    s_axis_tdata  : in  std_logic_vector(15 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;
    m_axis_tdata  : out std_logic_vector(15 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    ovf_event     : out std_logic;
    out_event     : out std_logic;
    busy          : out std_logic
  );
end entity;

architecture rtl of fir_decim is
  type state_t is (COLLECT, MAC, OUTPUT);
  type hist_t is array (0 to NTAPS - 1) of signed(15 downto 0);

  constant ACC_W : natural := 40;  -- 32 products of 31 bits + 5 growth bits, 3 spare

  signal state    : state_t := COLLECT;
  signal hist     : hist_t := (others => (others => '0'));  -- hist(k) = x[n-k]
  signal phase    : unsigned(3 downto 0) := (others => '0');
  signal idx      : unsigned(5 downto 0) := (others => '0');
  signal a_r, b_r : signed(15 downto 0) := (others => '0');
  signal prod_r   : signed(31 downto 0) := (others => '0');
  signal v1, v2   : std_logic := '0';  -- valid flags of the operand and product stages
  signal acc      : signed(ACC_W - 1 downto 0) := (others => '0');
  signal y_r      : std_logic_vector(15 downto 0) := (others => '0');
  signal s_rdy    : std_logic;
begin
  s_rdy <= '1' when state = COLLECT and enable = '1' and soft_rst = '0' else '0';
  s_axis_tready <= s_rdy;
  m_axis_tdata  <= y_r;
  m_axis_tvalid <= '1' when state = OUTPUT else '0';
  busy          <= '0' when state = COLLECT else '1';
  out_event     <= '1' when state = OUTPUT and m_axis_tready = '1' else '0';

  process (aclk)
    variable rnd : signed(ACC_W - 1 downto 0);
    variable q   : signed(ACC_W - 16 downto 0);
  begin
    if rising_edge(aclk) then
      ovf_event <= '0';

      -- MAC pipeline: operand registers -> product register -> accumulator.
      a_r <= hist(to_integer(idx(4 downto 0)));
      b_r <= coefs(to_integer(idx(4 downto 0)));
      if state = MAC and idx < NTAPS then
        v1 <= '1';
      else
        v1 <= '0';
      end if;
      prod_r <= a_r * b_r;
      v2     <= v1;
      if v2 = '1' then
        acc <= acc + resize(prod_r, ACC_W);
      end if;

      case state is
        when COLLECT =>
          if s_axis_tvalid = '1' and s_rdy = '1' then
            hist <= signed(s_axis_tdata) & hist(0 to NTAPS - 2);
            if phase = decim - 1 then
              phase <= (others => '0');
              idx   <= (others => '0');
              acc   <= (others => '0');
              state <= MAC;
            else
              phase <= phase + 1;
            end if;
          end if;

        when MAC =>
          if idx < NTAPS then
            idx <= idx + 1;
          elsif v1 = '0' and v2 = '0' then  -- pipeline drained, acc complete
            rnd := acc + 2**14;
            q   := rnd(ACC_W - 1 downto 15);
            if q > 32767 then
              y_r <= x"7FFF";
              ovf_event <= '1';
            elsif q < -32768 then
              y_r <= x"8000";
              ovf_event <= '1';
            else
              y_r <= std_logic_vector(q(15 downto 0));
            end if;
            state <= OUTPUT;
          end if;

        when OUTPUT =>
          if m_axis_tready = '1' then
            state <= COLLECT;
          end if;
      end case;

      if aresetn = '0' or soft_rst = '1' then
        state     <= COLLECT;
        hist      <= (others => (others => '0'));
        phase     <= (others => '0');
        idx       <= (others => '0');
        v1        <= '0';
        v2        <= '0';
        ovf_event <= '0';
      end if;
    end if;
  end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package fir_pkg is
  constant NTAPS : natural := 32;
  type coef_array_t is array (0 to NTAPS - 1) of signed(15 downto 0);
end package;

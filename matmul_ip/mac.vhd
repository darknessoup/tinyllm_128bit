----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 03/20/2024 06:38:51 PM
-- Design Name: 
-- Module Name: macc_dsp - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity macc_dsp is
  Port (
    clk: in std_logic;
    ce: in std_logic;
    clr_acc: in std_logic;
    a: in signed(7 downto 0);
    b: in signed(7 downto 0);
    accum_out: out signed(31 downto 0)
  );
end macc_dsp;

architecture Behavioral of macc_dsp is
attribute use_dsp : string;
attribute use_dsp of Behavioral : architecture is "yes";

--  Multiply-accumulate unit
--  The following code implements a parameterizable Multiply-accumulate unit
--  with synchronous load to reset the accumulator without losing a clock cycle
--  Size of inputs/output should be less than/equal to what is supported by the architecture else extra logic/dsps will be inferred
--  Below libraries need to be used
--  library ieee;
--  use ieee.std_logic_1164.all;
--  use ieee.numeric_std.all;

-- Declare registers for intermediate values
signal a_reg, b_reg           : signed (7 downto 0) := x"00";
signal sload_reg              : std_logic := '0';
signal mult_reg                 : signed (15 downto 0) := x"0000";
signal adder_out, old_result  : signed (31 downto 0) := x"00000000";
begin
-- Insert the below after begin keyword in architecture

process (adder_out, sload_reg)
 begin
  if sload_reg = '1' then
      old_result <= (others => '0');
  else
      -- 'sload' is now active (=low) and opens the accumulation loop.
      -- The accumulator takes the next multiplier output in
      -- the same cycle.
      old_result <= adder_out;
  end if;
end process;

process (clk)
 begin
  if rising_edge(clk) then
    if ce = '1' then
        a_reg     <= a;
        b_reg     <= b;
        mult_reg  <= a_reg * b_reg;
        sload_reg <= clr_acc;
        -- Store accumulation result into a register
        adder_out <= old_result + mult_reg;
    end if;
  end if;
end process;

 -- Output accumulation result
  accum_out <= adder_out;
				
				

end Behavioral;

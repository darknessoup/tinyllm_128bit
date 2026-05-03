----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 03/21/2024 11:01:15 PM
-- Design Name: 
-- Module Name: matmul_manager - Behavioral
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
use IEEE.std_logic_signed.all;
-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity matmul_manager is
	generic (
	   -- 32 weight input for both DMAs
		WEIGHT_TDATA_WIDTH	: integer	:= 128;
		OUTPUT_TDATA_WIDTH	: integer	:= 64;
		BRAM_ADDR_WIDTH	: integer	:= 12
	);
  Port (
    length: in unsigned(15 downto 0);
  	-- Ports of Axi Slave Bus Interface S00_AXIS
		s00_axis_aclk	: in std_logic;
		s00_axis_aresetn	: in std_logic;
		s00_axis_tready	: out std_logic;
		s00_axis_tdata	: in std_logic_vector(WEIGHT_TDATA_WIDTH-1 downto 0);
		s00_axis_tlast	: in std_logic;
		s00_axis_tvalid	: in std_logic;

		-- Ports of Axi Master Bus Interface M00_AXIS
--		m00_axis_aclk	: in std_logic;
--		m00_axis_aresetn	: in std_logic;
		m00_axis_tvalid	: out std_logic;
		m00_axis_tdata	: out std_logic_vector(OUTPUT_TDATA_WIDTH-1 downto 0);
		m00_axis_tlast	: out std_logic;
		m00_axis_tready	: in std_logic;

		-- Single 128-bit BRAM
		bram_din: in std_logic_vector(127 downto 0);
		bram_addr: out std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
		bram_en: out std_logic
		
  );
end matmul_manager;

architecture Behavioral of matmul_manager is
component macc_dsp is
  Port (
    clk: in std_logic;
    ce: in std_logic;
    clr_acc: in std_logic;
    a: in signed(7 downto 0);
    b: in signed(7 downto 0);
    accum_out: out signed(63 downto 0)
  );
end component;

type state_type is (idle, active, blocked, finishing, blocked_finishing, done);

signal state: state_type := idle;
signal macc_en, first_done, sum1_done, sum2_done, sum3_done, sum4_done, sum_done, result_ready, clr_acc: std_logic := '0';
signal sum1, sum2, sum3, sum4, sum5, sum6, sum7, sum8: std_logic_vector(67 downto 0) := (others => '0');
signal sum9, sum10, sum11, sum12: std_logic_vector(67 downto 0) := (others => '0');
signal sum13, sum14: std_logic_vector(67 downto 0) := (others => '0');
signal acc_out1, acc_out2, acc_out3, acc_out4, acc_out5, acc_out6, acc_out7, acc_out8: signed(63 downto 0) := (others => '0');
signal acc_out9, acc_out10, acc_out11, acc_out12, acc_out13, acc_out14, acc_out15, acc_out16: signed(63 downto 0) := (others => '0');
signal output_reg: std_logic_vector(OUTPUT_TDATA_WIDTH-1 downto 0) := (others => '0');
signal count, next_count: unsigned(7 downto 0) := to_unsigned(0, 8);
signal length_div16: unsigned(15 downto 0);
--signal bram_8bit : std_logic_vector(7 downto 0) := x"00";

--signal fake_bram: unsigned(15 downto 0) := to_unsigned(0, 16);

--constant BRAM_START_ADDR : std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0) := x"000";

begin

--bram_8bit <= bram_din(7 downto 0) when count(1 downto 0) = "00" else
--            bram_din(15 downto 8) when count(1 downto 0) = "01" else
--           bram_din(23 downto 16) when count(1 downto 0) = "10" else
--          bram_din(31 downto 24);

-- Combinatorial assignment for length divided by 16
length_div16 <= "0000" & length(15 downto 4);

macc1: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(7 downto 0)),
  b => signed(bram_din(7 downto 0)),
  accum_out => acc_out1
);
macc2: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(15 downto 8)),
  b => signed(bram_din(15 downto 8)),
  accum_out => acc_out2
);
macc3: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(23 downto 16)),
  b => signed(bram_din(23 downto 16)),
  accum_out => acc_out3
);
macc4: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(31 downto 24)),
  b => signed(bram_din(31 downto 24)),
  accum_out => acc_out4
);
macc5: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(39 downto 32)),
  b => signed(bram_din(39 downto 32)),
  accum_out => acc_out5
);
macc6: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(47 downto 40)),
  b => signed(bram_din(47 downto 40)),
  accum_out => acc_out6
);
macc7: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(55 downto 48)),
  b => signed(bram_din(55 downto 48)),
  accum_out => acc_out7
);
macc8: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(63 downto 56)),
  b => signed(bram_din(63 downto 56)),
  accum_out => acc_out8
);
macc9: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(71 downto 64)),
  b => signed(bram_din(71 downto 64)),
  accum_out => acc_out9
);
macc10: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(79 downto 72)),
  b => signed(bram_din(79 downto 72)),
  accum_out => acc_out10
);
macc11: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(87 downto 80)),
  b => signed(bram_din(87 downto 80)),
  accum_out => acc_out11
);
macc12: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(95 downto 88)),
  b => signed(bram_din(95 downto 88)),
  accum_out => acc_out12
);
macc13: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(103 downto 96)),
  b => signed(bram_din(103 downto 96)),
  accum_out => acc_out13
);
macc14: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(111 downto 104)),
  b => signed(bram_din(111 downto 104)),
  accum_out => acc_out14
);
macc15: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(119 downto 112)),
  b => signed(bram_din(119 downto 112)),
  accum_out => acc_out15
);
macc16: macc_dsp port map(
  clk => s00_axis_aclk,
  ce => macc_en,
  clr_acc => clr_acc,
  a => signed(s00_axis_tdata(127 downto 120)),
  b => signed(bram_din(127 downto 120)),
  accum_out => acc_out16
);
macc_en <= '1' when 
            (state = active and s00_axis_tvalid = '1') or
            state = finishing else '0';
clr_acc <= '1' when (count = 1 and sum_done = '1') or (count < 2 and sum_done = '0') else '0';
s00_axis_tready <= '1' when state = active else '0';
m00_axis_tvalid <= result_ready;
m00_axis_tdata <= output_reg;
m00_axis_tlast <= '1' when state = done else '0';
next_count <= (others => '0') when (state = idle or state = done or count = length_div16-1) else count + 1;
bram_en <= '1' when (state = idle or s00_axis_tvalid = '1') else '0';
bram_addr <= std_logic_vector("00" & next_count(7 downto 0) & "00");

process (s00_axis_aclk)
begin
  if rising_edge(s00_axis_aclk) then
--    if (state = idle or s00_axis_tvalid = '1') then
--      fake_bram <= next_count;
--    end if;
    if s00_axis_aresetn = '0' then
      state <= idle;
      first_done <= '0';
      count <= (others => '0');
    else
      case state is
        when idle =>
          -- Ready and waiting for VALID
          if s00_axis_tvalid = '1' then
            state <= active;
          end if;
        when active | finishing =>
          if macc_en = '1' then
            if s00_axis_tlast = '1' then
              state <= finishing;
            end if;
            
            if count = length_div16 - 1 then
              first_done <= '1';
            end if; 
            
            if count = 1 and result_ready = '1' then
              if state = finishing then
                state <= blocked_finishing;
              else
                state <= blocked;
              end if;
            elsif count = 2 and first_done = '1' then
              result_ready <= '1';
              -- 16 DSPs with 4-stage summation tree
              if sum4_done = '1' then -- final sum
                output_reg <= std_logic_vector(resize(signed(sum13) + signed(sum14), OUTPUT_TDATA_WIDTH));
                sum_done <= '1';
              elsif sum3_done = '1' then -- third stage sum
                sum13 <= std_logic_vector(resize(signed(sum9) + signed(sum10), 68));
                sum14 <= std_logic_vector(resize(signed(sum11) + signed(sum12), 68));
                sum4_done <= '1';
              elsif sum2_done = '1' then -- second stage sum
                sum9 <= std_logic_vector(resize(signed(sum1) + signed(sum2), 68));
                sum10 <= std_logic_vector(resize(signed(sum3) + signed(sum4), 68));
                sum11 <= std_logic_vector(resize(signed(sum5) + signed(sum6), 68));
                sum12 <= std_logic_vector(resize(signed(sum7) + signed(sum8), 68));
                sum3_done <= '1';
              elsif sum1_done = '1' then -- Stage 1: eight pairwise additions
                sum5 <= std_logic_vector(resize(signed(acc_out9) + signed(acc_out10), 68));
                sum6 <= std_logic_vector(resize(signed(acc_out11) + signed(acc_out12), 68));
                sum7 <= std_logic_vector(resize(signed(acc_out13) + signed(acc_out14), 68));
                sum8 <= std_logic_vector(resize(signed(acc_out15) + signed(acc_out16), 68));
                sum2_done <= '1';
              else
              -- Stage 0: first eight pairwise additions
                sum1 <= std_logic_vector(resize(signed(acc_out1) + signed(acc_out2), 68));
                sum2 <= std_logic_vector(resize(signed(acc_out3) + signed(acc_out4), 68));
                sum3 <= std_logic_vector(resize(signed(acc_out5) + signed(acc_out6), 68));
                sum4 <= std_logic_vector(resize(signed(acc_out7) + signed(acc_out8), 68));
                sum1_done <= '1';
              end if;
              if state = active and sum_done = '1' then
                count <= next_count;
              else
                state <= done;
              end if;
            else
              count <= next_count;
            end if;
          end if;
        when blocked =>
          if m00_axis_tready = '1' then
            state <= active;
            if s00_axis_tvalid = '1' then
              count <= next_count;
            end if;
          end if;
        when blocked_finishing =>
          if m00_axis_tready = '1' then
            state <= finishing;
            count <= next_count;
          end if;
        when done =>
          count <= next_count;
          first_done <= '0';
          sum1_done <= '0';
          sum2_done <= '0';
          sum3_done <= '0';
          sum4_done <= '0';
          if m00_axis_tready = '1' then
            state <= idle;
          end if;
        when others =>
          state <= idle;
      end case;
      if result_ready = '1' and m00_axis_tready = '1' then
        result_ready <= '0';
      end if;
    end if;
  end if;
end process;

end Behavioral;

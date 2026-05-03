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
		OUTPUT_TDATA_WIDTH	: integer	:= 32;
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
    accum_out: out signed(31 downto 0)
  );
end component;

type state_type is (idle, active, blocked, finishing, blocked_finishing, done);

signal state: state_type := idle;
signal macc_en, first_done, sum_done, result_ready, clr_acc: std_logic := '0';
signal flush_count: unsigned(1 downto 0) := (others => '0');
signal sum_stage1_1, sum_stage1_2, sum_stage1_3, sum_stage1_4: std_logic_vector(OUTPUT_TDATA_WIDTH-1 downto 0) := (others => '0');
signal sum_stage1_5, sum_stage1_6, sum_stage1_7, sum_stage1_8: std_logic_vector(OUTPUT_TDATA_WIDTH-1 downto 0) := (others => '0');
signal acc_out1, acc_out2, acc_out3, acc_out4, acc_out5, acc_out6, acc_out7, acc_out8: signed(OUTPUT_TDATA_WIDTH-1 downto 0) := (others => '0');
signal acc_out9, acc_out10, acc_out11, acc_out12, acc_out13, acc_out14, acc_out15, acc_out16: signed(OUTPUT_TDATA_WIDTH-1 downto 0) := (others => '0');
signal output_reg: std_logic_vector(OUTPUT_TDATA_WIDTH-1 downto 0) := (others => '0');
signal count, next_count: unsigned(7 downto 0) := to_unsigned(0, 8);
signal sum_valid: std_logic := '0';
signal length_div16: unsigned(15 downto 0);
constant SUM_OUTPUT : integer := OUTPUT_TDATA_WIDTH;
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
-- macc_en: active on valid weight beats, plus exactly 2 flush cycles in finishing
-- to drain the 2-stage MAC pipeline before the sum tree reads accum_out.
macc_en <= '1' when (state = active and s00_axis_tvalid = '1') or
                    (state = finishing and flush_count < 2) else '0';
-- clr_acc: only allowed in idle/done to prevent corrupting accumulators
-- during the finishing sum tree read (count=0, macc_en='0' would otherwise fire here)
clr_acc <= '1' when count = 0 and (state = idle or state = done) else '0';
s00_axis_tready <= '1' when state = active else '0';
m00_axis_tvalid <= result_ready;
m00_axis_tdata <= output_reg;
m00_axis_tlast <= '1' when state = done else '0';
next_count <= (others => '0') when (state = idle or state = done or count = length_div16-1) else count + 1;
bram_en <= '1' when (state = idle or s00_axis_tvalid = '1') else '0';
bram_addr <= std_logic_vector(resize(count, BRAM_ADDR_WIDTH));

process (s00_axis_aclk)
begin
  if rising_edge(s00_axis_aclk) then
    if s00_axis_aresetn = '0' then
      state <= idle;
      first_done <= '0';
      flush_count <= (others => '0');
      sum_done    <= '0';
      count <= (others => '0');
      sum_valid <= '0';
    else
      case state is
        when idle =>
          if s00_axis_tvalid = '1' then
            state <= active;
          end if;
        when active =>
          if macc_en = '1' then
            -- Check for early blocking if a prior result is not yet consumed
            if count = 1 and result_ready = '1' then
              state <= blocked;
            else
              if count = length_div16 - 1 then
                first_done <= '1';
              end if;
              -- Transition to finishing when the last AXI-Stream beat arrives
              if s00_axis_tlast = '1' then
                state <= finishing;
              end if;
              count <= next_count;
            end if;
          end if;

        when finishing =>
          -- flush_count < 2: keep macc_en='1' to drain the 2-stage MAC pipeline.
          -- Inputs (tdata/bram_din) are held from the last beat; 2 extra ce cycles
          -- are exactly what is needed to flush a[N-1]*b[N-1] into adder_out.
          if flush_count < 2 then
            flush_count <= flush_count + 1;
          -- Pipeline fully drained (macc_en now '0'): run sum tree.
          -- Stage 1: latch 8 pairwise sums
          elsif sum_done = '0' and sum_valid = '0' then
            sum_stage1_1 <= std_logic_vector(resize(signed(acc_out1)  + signed(acc_out2),  SUM_OUTPUT));
            sum_stage1_2 <= std_logic_vector(resize(signed(acc_out3)  + signed(acc_out4),  SUM_OUTPUT));
            sum_stage1_3 <= std_logic_vector(resize(signed(acc_out5)  + signed(acc_out6),  SUM_OUTPUT));
            sum_stage1_4 <= std_logic_vector(resize(signed(acc_out7)  + signed(acc_out8),  SUM_OUTPUT));
            sum_stage1_5 <= std_logic_vector(resize(signed(acc_out9)  + signed(acc_out10), SUM_OUTPUT));
            sum_stage1_6 <= std_logic_vector(resize(signed(acc_out11) + signed(acc_out12), SUM_OUTPUT));
            sum_stage1_7 <= std_logic_vector(resize(signed(acc_out13) + signed(acc_out14), SUM_OUTPUT));
            sum_stage1_8 <= std_logic_vector(resize(signed(acc_out15) + signed(acc_out16), SUM_OUTPUT));
            sum_valid <= '1';
          -- Stage 2: sum all 8 stage-1 outputs into output_reg.
          -- sum_stage1_x were REGISTERED at the end of Stage 1 (previous cycle)
          -- so their values are stable. We must NOT use intermediate signals here
          -- because signal assignments in a clocked process only take effect after
          -- the process finishes -- reading a signal being assigned in the same
          -- cycle would silently read its old (zero) value.
          elsif sum_valid = '1' then
            output_reg <= std_logic_vector(resize(
              signed(sum_stage1_1) + signed(sum_stage1_2) + signed(sum_stage1_3) + signed(sum_stage1_4) +
              signed(sum_stage1_5) + signed(sum_stage1_6) + signed(sum_stage1_7) + signed(sum_stage1_8),
              SUM_OUTPUT));
            result_ready <= '1';
            sum_done     <= '1';
            sum_valid    <= '0';
            -- Wait for downstream to accept before moving to done
            if m00_axis_tready = '1' then
              state <= done;
            else
              state <= blocked_finishing;
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
            state <= done;
          end if;
        when done =>
          count       <= next_count;
          first_done  <= '0';
          flush_count <= (others => '0');
          sum_done    <= '0';
          if m00_axis_tready = '1' then
            state <= idle;
          end if;
        when others =>
          state <= idle;
      end case;
      
      -- Clear result_ready after handshake
      if result_ready = '1' and m00_axis_tready = '1' then
        result_ready <= '0';
      end if;
    end if;
  end if;
end process;

end Behavioral;

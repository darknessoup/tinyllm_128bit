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
type acc_array_type is array (1 to 16) of signed(OUTPUT_TDATA_WIDTH-1 downto 0);
type sum_stage1_type is array (1 to 8) of signed(OUTPUT_TDATA_WIDTH downto 0);  -- One extra bit for addition
type sum_stage2_type is array (1 to 4) of signed(OUTPUT_TDATA_WIDTH+1 downto 0);  -- Two extra bits
type sum_stage3_type is array (1 to 2) of signed(OUTPUT_TDATA_WIDTH+2 downto 0);  -- Three extra bits

signal state: state_type := idle;
signal macc_en, first_done, result_ready, clr_acc: std_logic := '0';
signal acc_out: acc_array_type := (others => (others => '0'));
signal sum_stage1_reg, sum_stage1_comb: sum_stage1_type := (others => (others => '0'));
signal sum_stage2_reg, sum_stage2_comb: sum_stage2_type := (others => (others => '0'));
signal sum_stage3_reg, sum_stage3_comb: sum_stage3_type := (others => (others => '0'));
signal output_reg: std_logic_vector(OUTPUT_TDATA_WIDTH-1 downto 0) := (others => '0');
signal count, next_count: unsigned(7 downto 0) := to_unsigned(0, 8);
signal row_addr: unsigned(BRAM_ADDR_WIDTH-1 downto 0) := to_unsigned(0, BRAM_ADDR_WIDTH);  -- tracks which activation row
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

macc_gen: for idx in 1 to 16 generate 
  macc_i: macc_dsp port map(
    clk => s00_axis_aclk,
    ce => macc_en,
    clr_acc => clr_acc,
    a => signed(s00_axis_tdata(8*idx-1 downto 8*idx-8)),
    b => signed(bram_din(8*idx-1 downto 8*idx-8)),
    accum_out => acc_out(idx)
  );
end generate macc_gen;

-- ============================================================================
-- 4-Stage Tree Reduction Pipeline (combinatorial stage functions)
-- ============================================================================
-- Stage 1: 16 accumulator outputs -> 8 partial sums (adjacent pairs)
stage1_gen: for idx in 1 to 8 generate
  sum_stage1_comb(idx) <= resize(acc_out(2*idx-1), OUTPUT_TDATA_WIDTH+1) + 
                          resize(acc_out(2*idx), OUTPUT_TDATA_WIDTH+1);
end generate stage1_gen;

-- Stage 2: 8 partial sums -> 4 sums (adjacent pairs)
stage2_gen: for idx in 1 to 4 generate
  sum_stage2_comb(idx) <= resize(sum_stage1_reg(2*idx-1), OUTPUT_TDATA_WIDTH+2) + 
                          resize(sum_stage1_reg(2*idx), OUTPUT_TDATA_WIDTH+2);
end generate stage2_gen;

-- Stage 3: 4 partial sums -> 2 sums (adjacent pairs)
stage3_gen: for idx in 1 to 2 generate
  sum_stage3_comb(idx) <= resize(sum_stage2_reg(2*idx-1), OUTPUT_TDATA_WIDTH+3) + 
                          resize(sum_stage2_reg(2*idx), OUTPUT_TDATA_WIDTH+3);
end generate stage3_gen;

-- ============================================================================
-- Control Signals
-- ============================================================================
-- macc_en: active on valid weight beats and throughout finishing state
-- to allow the 2-stage MAC pipeline to drain naturally
macc_en <= '1' when (state = active and s00_axis_tvalid = '1') or
                    state = finishing else '0';
-- clr_acc: fires on the first two ce='1' cycles of each new dot product
-- to zero the accumulator while the pipeline warms up
clr_acc <= '1' when (count = 1 and first_done = '1') or (count < 2 and first_done = '0') else '0';
s00_axis_tready <= '1' when state = active else '0';
m00_axis_tvalid <= result_ready;
m00_axis_tdata <= output_reg;
m00_axis_tlast <= '1' when state = done else '0';
-- Allow count to continue incrementing past length_div16 for pipeline draining
-- Only wrap to 0 when idle or done
next_count <= (others => '0') when (state = idle or state = done) else count + 1;
bram_en <= '1' when (state = idle or s00_axis_tvalid = '1') else '0';
-- BRAM address steps through consecutive rows: row_addr * length_div16 + count
-- This ensures each computation reads all its activation data sequentially
bram_addr <= std_logic_vector(resize(row_addr * resize(length_div16, BRAM_ADDR_WIDTH) + resize(count, BRAM_ADDR_WIDTH), BRAM_ADDR_WIDTH));

process (s00_axis_aclk)
begin
  if rising_edge(s00_axis_aclk) then
    if s00_axis_aresetn = '0' then
      state <= idle;
      first_done <= '0';
      count <= (others => '0');
      sum_stage1_reg <= (others => (others => '0'));
      sum_stage2_reg <= (others => (others => '0'));
      sum_stage3_reg <= (others => (others => '0'));
    else
      -- Clear pipeline stages only during initial warm-up (first two cycles of first row)
      -- Specifically when both clr_acc is firing AND first_done hasn't been set yet (first row only)
      if clr_acc = '1' and first_done = '0' then
        sum_stage1_reg <= (others => (others => '0'));
        sum_stage2_reg <= (others => (others => '0'));
        sum_stage3_reg <= (others => (others => '0'));
      else
        -- Pipeline the reduction stages: each cycle advances the partial sums
        sum_stage1_reg <= sum_stage1_comb;
        sum_stage2_reg <= sum_stage2_comb;
        sum_stage3_reg <= sum_stage3_comb;
      end if;
      case state is
        when idle =>
          if s00_axis_tvalid = '1' then
            state <= active;
          end if;
        when active | finishing =>
          if macc_en = '1' then
            -- tlast marks the final row; state drives done vs continue at count=2
            if s00_axis_tlast = '1' then
              state <= finishing;
            end if;

            if count = length_div16 - 1 then
              first_done <= '1';
            end if;

            -- Backpressure check disabled for debugging: may cause count stuck at 1
            -- if count = 1 and result_ready = '1' then
            --   if state = finishing then
            --     state <= blocked_finishing;
            --   else
            --     state <= blocked;
            --   end if;
            -- elsif
            if count = 4 and first_done = '1' then
              -- 4-Stage Reduction Pipeline:
              -- The 2-cycle MAC pipeline drains through cycles 0,1.
              -- Cycle 2: Stage 1 reduction computed and registered
              -- Cycle 3: Stage 2 reduction computed and registered
              -- Cycle 4: Stage 3 reduction computed and registered
              -- At count=4, read sum_stage3_reg (the registered stage 3 result)
              result_ready <= '1';
              if state = active then
                count <= next_count;  -- more rows to process
              else
                state <= done;        -- last row: wait for handshake
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
            state <= finishing;   -- resume finishing to hit count=2 trigger
            count <= next_count;
          end if;
        when done =>
          count      <= next_count;
          first_done <= '0';
          if m00_axis_tready = '1' then
            state <= idle;
            row_addr <= row_addr + 1;  -- Move to next activation row
          end if;
        when others =>
          state <= idle;
      end case;
      
      -- Capture output at count=4 (always, not dependent on macc_en)
      if count = 4 and first_done = '1' then
        output_reg <= std_logic_vector(resize(
          sum_stage3_comb(1) + sum_stage3_comb(2),
          SUM_OUTPUT));
        -- In finishing state with pipeline drained, we're ready to transition to done
        -- (m00_axis_tlast will be asserted on next cycle when state = done)
      end if;
      
      -- Clear result_ready after handshake
      if result_ready = '1' and m00_axis_tready = '1' then
        result_ready <= '0';
      end if;
    end if;
  end if;
end process;

end Behavioral;

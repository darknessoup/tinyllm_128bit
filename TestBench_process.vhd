----------------------------------------------------------------------------------
-- Module Name: matmul_timing_tb - Behavioral
-- Description:
--   Single-cycle timing testbench for matmul_v1_0.
--
--   Purpose: Validate that the component reads 128-bit activations from BRAM
--   and performs MAC operations against 128-bit weight beats from DDR/DMA.
--
--   Test vectors:
--     Activations (BRAM addr 0): 16x [1,1,1,...,1] = 0x01010101010101010101010101010101
--     Weights (AXI-Stream beats): [1,2,3,...,16] per beat, 2 beats total
--     vec_len = 32  =>  length_div16 = 2 (two 16-element chunks)
--
--   Expected result: sum(i * 1, i=1..16) * 2 beats = 272 = 0x0110
--   Observe on waveform: m00_axis_tdata = 0x0000000000000088 when tvalid rises.
--
--   Key signals to probe
--     addra        : BRAM read address (should be 0x000)
--     ena          : BRAM enable (high during idle pre-fetch and active)
--     douta        : activation data from BRAM (0x01010101010101010101010101010101)
--     s00_axis_tready : high when manager is in 'active' state
--     m00_axis_tvalid : rises when result is ready
--     m00_axis_tdata  : expected 0x00000088 (136 decimal, 32-bit)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity matmul_timing_tb is
end matmul_timing_tb;

architecture Behavioral of matmul_timing_tb is

component matmul_0 is
port (
    addra : out std_logic_vector(11 downto 0);
    clka : out std_logic;
    dina : out std_logic_vector(127 downto 0);
    douta : in std_logic_vector(127 downto 0);
    ena : out std_logic;
    rsta : out std_logic;
    wea : out std_logic_vector(15 downto 0);
    s00_axi_aclk : IN STD_LOGIC;
    s00_axi_aresetn : IN STD_LOGIC;
    s00_axi_awaddr : IN STD_LOGIC_VECTOR(4 DOWNTO 0);
    s00_axi_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    s00_axi_awvalid : IN STD_LOGIC;
    s00_axi_awready : OUT STD_LOGIC;
    s00_axi_wdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    s00_axi_wstrb : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    s00_axi_wvalid : IN STD_LOGIC;
    s00_axi_wready : OUT STD_LOGIC;
    s00_axi_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    s00_axi_bvalid : OUT STD_LOGIC;
    s00_axi_bready : IN STD_LOGIC;
    s00_axi_araddr : IN STD_LOGIC_VECTOR(4 DOWNTO 0);
    s00_axi_arprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    s00_axi_arvalid : IN STD_LOGIC;
    s00_axi_arready : OUT STD_LOGIC;
    s00_axi_rdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    s00_axi_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    s00_axi_rvalid : OUT STD_LOGIC;
    s00_axi_rready : IN STD_LOGIC;
    axis_aclk : IN STD_LOGIC;
    axis_aresetn : IN STD_LOGIC;
    s00_axis_tready : OUT STD_LOGIC;
    s00_axis_tdata : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
    s00_axis_tstrb : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
    s00_axis_tlast : IN STD_LOGIC;
    s00_axis_tvalid : IN STD_LOGIC;
    m00_axis_tvalid : OUT STD_LOGIC;
    m00_axis_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    m00_axis_tstrb : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    m00_axis_tlast : OUT STD_LOGIC;
    m00_axis_tready : IN STD_LOGIC
);
end component;

-- True dual-port BRAM: 128-bit wide, 1024 deep.
-- Port A read by matmul_v1_0 (activations). Port B written by testbench.
COMPONENT blk_mem_dp_32_1024
  PORT (
    clka : IN STD_LOGIC;
    rsta : IN STD_LOGIC;
    ena : IN STD_LOGIC;
    wea : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
    addra : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    dina : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
    douta : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
    clkb : IN STD_LOGIC;
    rstb : IN STD_LOGIC;
    enb : IN STD_LOGIC;
    web : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
    addrb : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    dinb : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
    doutb : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
    rsta_busy : OUT STD_LOGIC;
    rstb_busy : OUT STD_LOGIC
  );
END COMPONENT;

signal clk, resetn, reset, go : std_logic := '0';
signal ena, rsta               : std_logic;
signal wea : std_logic_vector(15 downto 0) := (others => '0');
signal web : std_logic_vector(15 downto 0) := (others => '0');
signal addra : std_logic_vector(11 downto 0);
signal addrb : std_logic_vector(31 downto 0) := (others => '0');
signal dinb  : std_logic_vector(127 downto 0) := (others => '0');
signal doutb : std_logic_vector(127 downto 0);  -- PORT B output for diagnostics
signal rsta_busy, rstb_busy : std_logic;

signal s00_axi_wdata  : std_logic_vector(31 downto 0);
signal douta, dina    : std_logic_vector(127 downto 0);
signal s00_axi_awaddr : std_logic_vector(4 downto 0);
signal s00_axi_awvalid, s00_axi_wvalid, s00_axi_bready,
       s00_axi_awready, s00_axi_wready, s00_axi_bvalid : std_logic;

signal s00_axis_tvalid, s00_axis_tlast, s00_axis_tready : std_logic := '0';
signal m00_axis_tready, m00_axis_tvalid, m00_axis_tlast : std_logic := '0';
signal s00_axis_tdata   : std_logic_vector(127 downto 0) := (others => '0');
signal s00_axis_tstrb   : std_logic_vector(15 downto 0)  := (others => '0');
signal m00_axis_tdata   : std_logic_vector(31 downto 0)  := (others => '0');
signal m00_axis_tstrb   : std_logic_vector(3 downto 0)   := (others => '0');

constant clk_period : time := 10 ns;

begin

blk_mem_inst : blk_mem_dp_32_1024
  port map (
    rsta => rsta,
    clka => clk,
    ena  => ena,
    wea  => wea,
    addra(11 downto 0)  => addra,
    addra(31 downto 12) => (others => '0'),
    dina  => dina,
    douta => douta,
    rstb  => rsta,
    clkb  => clk,
    enb   => '1',
    web   => web,
    addrb  => addrb,
    dinb  => dinb,
    doutb => doutb
  );

inst_matmul_v1_0 : matmul_0
    port map (
        s00_axi_aclk    => clk,
        s00_axi_aresetn => resetn,
        s00_axi_awaddr  => s00_axi_awaddr,
        s00_axi_awprot  => (others => '0'),
        s00_axi_awvalid => s00_axi_awvalid,
        s00_axi_awready => s00_axi_awready,
        s00_axi_wdata   => s00_axi_wdata,
        s00_axi_wstrb   => (others => '1'),
        s00_axi_wvalid  => s00_axi_wvalid,
        s00_axi_wready  => s00_axi_wready,
        s00_axi_bvalid  => s00_axi_bvalid,
        s00_axi_bready  => s00_axi_bready,
        s00_axi_araddr  => (others => '0'),
        s00_axi_arprot  => (others => '0'),
        s00_axi_arvalid => '0',
        s00_axi_rready  => '1',

        axis_aclk       => clk,
        axis_aresetn    => resetn,
        s00_axis_tready => s00_axis_tready,
        s00_axis_tdata  => s00_axis_tdata,
        s00_axis_tstrb  => s00_axis_tstrb,
        s00_axis_tlast  => s00_axis_tlast,
        s00_axis_tvalid => s00_axis_tvalid,
        m00_axis_tvalid => m00_axis_tvalid,
        m00_axis_tdata  => m00_axis_tdata,
        m00_axis_tstrb  => m00_axis_tstrb,
        m00_axis_tlast  => m00_axis_tlast,
        m00_axis_tready => m00_axis_tready,

        addra => addra,
        dina  => dina,
        douta => douta,
        ena   => ena,
        rsta  => rsta,
        wea   => wea
    );

clk_process : process
begin
    clk <= '0'; wait for clk_period/2;
    clk <= '1'; wait for clk_period/2;
end process;

main_stim : process
procedure write_axi(constant addr : in integer;
                    constant data : in std_logic_vector(31 downto 0)) is
begin
    s00_axi_wdata   <= data;
    s00_axi_awaddr  <= "00000";
    s00_axi_awvalid <= '1';
    s00_axi_wvalid  <= '1';
    s00_axi_bready  <= '1';
    if s00_axi_awready = '0' then wait until s00_axi_awready = '1'; end if;
    if s00_axi_wready  = '0' then wait until s00_axi_wready  = '1'; end if;
    wait for clk_period + clk_period/2;
    s00_axi_awvalid <= '0';
    s00_axi_wvalid  <= '0';
    wait for clk_period/2;
    if s00_axi_bvalid = '0' then wait until s00_axi_bvalid = '1'; end if;
    wait for clk_period + clk_period/2;
    s00_axi_bready  <= '0';
    wait for clk_period/2;
end procedure;

begin
    -- Step 1: Assert reset and write activations into BRAM port B.
    -- For vec_len=32 (length_div16=2), manager expects 2 BRAM addresses per computation.
    -- Computation 1 (row_addr=0): reads addresses 0,1 (all 1's)
    -- Computation 2 (row_addr=1): reads addresses 2,3 (all 2's)
    resetn <= '0';
    
    -- Force PORT A enable during writes so we can verify BRAM data
    -- (Normally ena is controlled by manager, but during init it may be 0)
    -- We need to manually strobe PORT A to verify writes committed
    
    -- Write TEST 1 activations (0x010101) to addresses 0, 1
    addrb  <= (others => '0');
    dinb   <= x"01010101010101010101010101010101";
    web    <= x"FFFF";
    wait for clk_period * 2;
    
    addrb  <= x"00000001";
    dinb   <= x"01010101010101010101010101010101";
    wait for clk_period * 2;
    
    -- Write TEST 2 activations (0x020202) to addresses 2, 3
    addrb  <= x"00000002";
    dinb   <= x"02020202020202020202020202020202";
    wait for clk_period * 2;
    
    addrb  <= x"00000003";
    dinb   <= x"02020202020202020202020202020202";
    wait for clk_period * 2;
    
    web    <= x"0000";

    -- Step 1b: Verification - ensure BRAM writes completed
    -- (Watch doutb signal on waveform - should show the values you wrote)
    wait for clk_period;
    -- At this point:
    -- - addrb = 0x00000003, doutb should show 0x02020202... (last value written)
    -- - If doutb shows 0x00000000, BRAM writes may not have worked
    wait for clk_period * 3;

    -- Step 2: Release reset, allow AXI slave to initialise.
    resetn <= '1';
    addrb  <= (others => '0');
    wait for 40 ns;

    -- Step 3: Write vec_len = 32 via AXI4-Lite (two 16-element chunks).
    -- length_div16 = 32/16 = 2: manager expects two BRAM words per computation.
    write_axi(0, std_logic_vector(to_unsigned(32, 32)));
    wait for 20 ns;

    -- Step 4: Assert downstream ready so results are consumed immediately.
    m00_axis_tready <= '1';
    wait until rising_edge(clk);

    -- ========================================================================
    -- TEST 1: FIRST computation with BRAM addr 0 (0x010101 activations)
    -- ========================================================================
    -- Step 5: Send TWO 128-bit weight beats (tlast=0, then tlast=1).
    -- Beat 1: Weights [1,2,3,...,16] with tlast=0 (more data coming)
    -- Beat 2: Weights [1,2,3,...,16] with tlast=1 (last beat, computation complete)
    -- Activations (BRAM addr 0): 0x01010101... (all 1's)
    -- Expected: sum(i * 1, i=1..32) = (1+2+...+16) * 2 = 272 = 0x0110
    
    -- Beat 1 (not last)
    s00_axis_tdata  <= x"0102030405060708090a0b0c0d0e0f10";
    s00_axis_tstrb  <= x"FFFF";
    s00_axis_tvalid <= '1';
    s00_axis_tlast  <= '0';  -- More beats follow
    loop
        wait until rising_edge(clk);
        exit when s00_axis_tready = '1';
    end loop;
    
    -- Beat 2 (last)
    s00_axis_tdata  <= x"0102030405060708090a0b0c0d0e0f10";
    s00_axis_tstrb  <= x"FFFF";
    s00_axis_tvalid <= '1';
    s00_axis_tlast  <= '1';  -- Last beat
    loop
        wait until rising_edge(clk);
        exit when s00_axis_tready = '1';
    end loop;
    s00_axis_tvalid <= '0';
    s00_axis_tlast  <= '0';

    -- Step 6: Wait for first result to appear.
    wait until m00_axis_tvalid = '1';
    wait for 30 ns;  -- Hold result on waveform
    
    -- Step 7: Wait for manager to return to idle (result_ready clears).
    wait until m00_axis_tvalid = '0';
    wait for 50 ns;  -- Extra settle time

    -- ========================================================================
    -- TEST 2: SECOND computation with BRAM addr 1 (0x020202 activations)
    -- ========================================================================
    -- Step 8: Send TWO 128-bit weight beats (tlast=0, then tlast=1).
    -- Beat 1: Weights [1,2,3,...,16] with tlast=0 (more data coming)
    -- Beat 2: Weights [1,2,3,...,16] with tlast=1 (last beat, computation complete)
    -- Activations (BRAM addr 1): 0x02020202... (all 2's)
    -- Expected: sum(i * 2, i=1..32) = (1+2+...+16) * 2 * 2 = 544 = 0x0220
    
    -- Beat 1 (not last)
    s00_axis_tdata  <= x"0102030405060708090a0b0c0d0e0f10";
    s00_axis_tstrb  <= x"FFFF";
    s00_axis_tvalid <= '1';
    s00_axis_tlast  <= '0';  -- More beats follow
    loop
        wait until rising_edge(clk);
        exit when s00_axis_tready = '1';
    end loop;
    
    -- Beat 2 (last)
    s00_axis_tdata  <= x"0102030405060708090a0b0c0d0e0f10";
    s00_axis_tstrb  <= x"FFFF";
    s00_axis_tvalid <= '1';
    s00_axis_tlast  <= '1';  -- Last beat
    loop
        wait until rising_edge(clk);
        exit when s00_axis_tready = '1';
    end loop;
    s00_axis_tvalid <= '0';
    s00_axis_tlast  <= '0';

    wait;
end process;

end Behavioral;

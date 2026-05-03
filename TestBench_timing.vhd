----------------------------------------------------------------------------------
-- Module Name: matmul_timing_tb - Behavioral
-- Description:
--   Single-cycle timing testbench for matmul_v1_0.
--
--   Purpose: confirm that the component reads one 128-bit word from BRAM
--   (activations) and performs exactly one MAC cycle against one 128-bit
--   weight beat, producing the correct result on m00_axis_tdata.
--
--   Test vectors
--     Activations (BRAM addr 0): byte[i] = i  (0x00, 0x01, ..., 0x0F)
--     Weights (AXI-Stream beat):  byte[i] = 1  (x"01010101010101010101010101010101")
--     vec_len = 16  =>  length_div16 = 1  (one BRAM word, one weight beat)
--
--   Expected result:  sum(i * 1, i=0..15) = 120 = 0x78
--   Observe on waveform: m00_axis_tdata = 0x0000000000000078 when tvalid rises.
--
--   Key signals to probe
--     addra        : BRAM read address (should be 0x000)
--     ena          : BRAM enable (high during idle pre-fetch and active)
--     douta        : activation data from BRAM (0x0f0e0d0c0b0a09080706050403020100)
--     s00_axis_tready : high when manager is in 'active' state
--     m00_axis_tvalid : rises when result is ready
--     m00_axis_tdata  : expected 0x0000000000000078
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity matmul_timing_tb is
end matmul_timing_tb;

architecture Behavioral of matmul_timing_tb is

component matmul_v1_0 is
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
    s00_axi_wstrb : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
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
    m00_axis_tdata : OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
    m00_axis_tstrb : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    m00_axis_tlast : OUT STD_LOGIC;
    m00_axis_tready : IN STD_LOGIC
);
end component;

-- True dual-port BRAM: 128-bit wide, 1024 deep.
-- Port A read by matmul_v1_0 (activations). Port B written by testbench.
COMPONENT blk_mem_dp_128_1024
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

signal s00_axi_wdata  : std_logic_vector(31 downto 0);
signal douta, dina    : std_logic_vector(127 downto 0);
signal s00_axi_awaddr : std_logic_vector(4 downto 0);
signal s00_axi_awvalid, s00_axi_wvalid, s00_axi_bready,
       s00_axi_awready, s00_axi_wready, s00_axi_bvalid : std_logic;

signal s00_axis_tvalid, s00_axis_tlast, s00_axis_tready : std_logic := '0';
signal m00_axis_tready  : std_logic := '0';
signal s00_axis_tdata   : std_logic_vector(127 downto 0) := (others => '0');
signal s00_axis_tstrb   : std_logic_vector(15 downto 0)  := (others => '0');

constant clk_period : time := 10 ns;

begin

blk_mem_inst : blk_mem_dp_128_1024
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
    addrb => (others => '0'),
    -- Activation bytes: byte[0]=0x00, byte[1]=0x01, ..., byte[15]=0x0F
    dinb  => x"0f0e0d0c0b0a09080706050403020100",
    doutb => open
  );

inst_matmul_v1_0 : matmul_v1_0
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
    -- web=x"FFFF" commits dinb (bytes 0x00..0x0F) to address 0 during reset
    -- so the data is stable before the manager pre-fetches address 0 on release.
    resetn <= '0';
    web    <= x"FFFF";
    wait for clk_period * 2;
    web    <= x"0000";

    -- Step 2: Release reset, allow AXI slave to initialise.
    resetn <= '1';
    wait for 40 ns;

    -- Step 3: Write vec_len = 16 via AXI4-Lite.
    -- length_div16 = 16/16 = 1: manager expects exactly one BRAM word and one
    -- weight beat before it produces a result.
    write_axi(0, std_logic_vector(to_unsigned(16, 32)));
    wait for 20 ns;

    -- Step 4: Assert downstream ready so the result is consumed immediately.
    m00_axis_tready <= '1';
    wait until rising_edge(clk);

    -- Step 5: Send ONE 128-bit weight beat, all bytes = 0x01, tlast asserted.
    -- MAC sum = 0*1 + 1*1 + ... + 15*1 = 120 = 0x78
    s00_axis_tdata  <= x"01010101010101010101010101010101";
    s00_axis_tstrb  <= x"FFFF";
    s00_axis_tvalid <= '1';
    s00_axis_tlast  <= '1';
    wait until rising_edge(clk);
    while s00_axis_tready /= '1' loop
        wait until rising_edge(clk);
    end loop;
    s00_axis_tvalid <= '0';
    s00_axis_tlast  <= '0';

    -- Step 6: Wait for m00_axis_tvalid.
    -- m00_axis_tdata should equal 0x0000000000000078.
    -- The 4-stage adder tree in matmul_manager adds several clock cycles of
    -- latency between the weight beat being accepted and tvalid rising.
    wait until m00_axis_tvalid = '1';
    wait for 50 ns;  -- keep result visible in waveform

    wait;
end process;

end Behavioral;

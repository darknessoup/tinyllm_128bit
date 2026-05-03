----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 03/21/2024 05:16:37 PM
-- Design Name: 
-- Module Name: matmul_tb - Behavioral
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

entity matmul_tb is
--  Port ( );
end matmul_tb;

architecture Behavioral of matmul_tb is
-- matmul_0: top-level wrapper integrating 16-DSP parallel MAC engine.
-- BRAM port A is read-only from the FPGA side (activations); dina is tied to
-- zeros and wea is all-zeros inside the IP. Port B is written by the PS via CDMA.
-- AXI4-Lite (32-bit) carries the vec_len register; AXI4-Stream slave is 128-bit
-- (16 x 8-bit weights per beat); AXI4-Stream master is 64-bit (one neuron result).
component matmul_v1_0 is
port (
    addra : out std_logic_vector(11 downto 0);  -- 12-bit BRAM address (port A)
    clka : out std_logic;
    dina : out std_logic_vector(127 downto 0);  -- tied to zeros inside IP (read-only port)
    douta : in std_logic_vector(127 downto 0);  -- 128-bit activation data read from BRAM
    ena : out std_logic;
    rsta : out std_logic;
    wea : out std_logic_vector(15 downto 0);    -- 16 byte-enables for 128-bit BRAM (all zeros)
    s00_axi_aclk : IN STD_LOGIC;
    s00_axi_aresetn : IN STD_LOGIC;
    s00_axi_awaddr : IN STD_LOGIC_VECTOR(4 DOWNTO 0);
    s00_axi_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    s00_axi_awvalid : IN STD_LOGIC;
    s00_axi_awready : OUT STD_LOGIC;
    s00_axi_wdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);   -- AXI4-Lite is 32-bit (vec_len register)
    s00_axi_wstrb : IN STD_LOGIC_VECTOR(15 DOWNTO 0);   -- NOTE: should be 3 downto 0 for 32-bit AXI-Lite
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
    s00_axis_tdata : IN STD_LOGIC_VECTOR(127 DOWNTO 0); -- 16 x 8-bit weights per beat (128-bit wide)
    s00_axis_tstrb : IN STD_LOGIC_VECTOR(15 DOWNTO 0);  -- 1 strobe bit per byte (16 bytes)
    s00_axis_tlast : IN STD_LOGIC;
    s00_axis_tvalid : IN STD_LOGIC;
    m00_axis_tvalid : OUT STD_LOGIC;
    m00_axis_tdata : OUT STD_LOGIC_VECTOR(63 DOWNTO 0); -- 64-bit neuron accumulator result
    m00_axis_tstrb : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);  -- 8 strobe bits for 8-byte output
    m00_axis_tlast : OUT STD_LOGIC;
    m00_axis_tready : IN STD_LOGIC 
	);
end component;

-- True dual-port BRAM: 128-bit wide, 1024 deep.
-- Port A: driven by matmul_0 (read-only for activations; address increments per beat).
-- Port B: written by testbench to simulate PS CDMA loading activation vectors.
-- wea/web are 16 bits because 128-bit width = 16 byte lanes, one enable per lane.
COMPONENT blk_mem_dp_128_1024
  PORT (
    clka : IN STD_LOGIC;
    rsta : IN STD_LOGIC;
    ena : IN STD_LOGIC;
    wea : IN STD_LOGIC_VECTOR(15 DOWNTO 0);  -- 16 byte-enables for port A
    addra : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    dina : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
    douta : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
    clkb : IN STD_LOGIC;
    rstb : IN STD_LOGIC;
    enb : IN STD_LOGIC;
    web : IN STD_LOGIC_VECTOR(15 DOWNTO 0);  -- 16 byte-enables for port B
    addrb : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    dinb : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
    doutb : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
    rsta_busy : OUT STD_LOGIC;
    rstb_busy : OUT STD_LOGIC 
  );
END COMPONENT;

signal clk, resetn, reset, go: std_logic := '0';
signal ena, rsta : std_logic;
-- wea/web are 16-bit: one enable bit per byte lane of the 128-bit BRAM.
-- wea is always zero (port A is read-only). web is pulsed to simulate CDMA writes.
signal wea : std_logic_vector(15 downto 0) := (others => '0');
signal web : std_logic_vector(15 downto 0) := (others => '0');
signal addra : std_logic_vector(11 downto 0);  -- shared BRAM address driven by matmul_0

-- AXI4-Lite is 32-bit (carries only the vec_len register at offset 0x0)
signal s00_axi_wdata : std_logic_vector(31 downto 0);
-- dina/douta are 128-bit: the full activation vector width read per BRAM beat
signal douta, dina : std_logic_vector(127 downto 0);
signal s00_axi_awaddr	: std_logic_vector(4 downto 0);
signal s00_axi_awvalid, 
        s00_axi_wvalid, 
        s00_axi_bready, 
        s00_axi_awready, 
        s00_axi_wready, 
        s00_axi_bvalid : std_logic;

-- AXI4-Stream slave: 128-bit data (16 x 8-bit weight bytes per beat)
signal s00_axis_tvalid, s00_axis_tlast, s00_axis_tready: std_logic := '0';
signal m00_axis_tready: std_logic := '0';
signal s00_axis_tdata	: std_logic_vector(127 downto 0) := (others => '0');
signal s00_axis_tstrb	: std_logic_vector(15 downto 0) := (others => '0');  -- 1 bit per byte lane

constant clk_period : time := 10 ns;

begin

-- BRAM instantiation: 128-bit wide, 1024 entries.
-- Port A is controlled by matmul_0 (address driven by the IP, data read as activations).
-- Port B is fixed at address 0 with a known test pattern so the testbench can write
-- one 128-bit word of activation data by pulsing web. dinb holds bytes 0x00..0x0F
-- so each byte lane has a distinct value for easy waveform verification.
blk_mem_inst : blk_mem_dp_128_1024
  port map (
    rsta => rsta,
    clka => clk,
    ena => ena,
    wea => wea,                              -- always zero: port A is read-only
    addra(11 downto 0) => addra,             -- 12-bit address from matmul_0
    addra(31 downto 12) => (others => '0'), -- upper bits unused
    dina => dina,                            -- tied to zeros inside matmul_0
    douta => douta,                          -- activation data returned to matmul_0
    rstb => rsta,
    clkb => clk,
    enb => '1',
    web => web,                              -- pulsed x"FFFF" to simulate CDMA write
    addrb => (others => '0'),               -- fixed address 0 for test writes
    dinb => x"0f0e0d0c0b0a09080706050403020100",  -- test activation: bytes 0x00..0x0F
    doutb => open
  );
	
inst_matmul_v1_0: matmul_v1_0
    port map (
        s00_axi_aclk       => clk,
        s00_axi_aresetn    => resetn,
        s00_axi_awaddr     => s00_axi_awaddr,
        s00_axi_awprot     => (others => '0'),
        s00_axi_awvalid    => s00_axi_awvalid,
        s00_axi_awready    => s00_axi_awready,
        s00_axi_wdata      => s00_axi_wdata,
        s00_axi_wstrb      => (others => '1'),
        s00_axi_wvalid     => s00_axi_wvalid,
        s00_axi_wready     => s00_axi_wready,
        s00_axi_bvalid     => s00_axi_bvalid,
        s00_axi_bready     => s00_axi_bready,
        s00_axi_araddr     => (others => '0'),
        s00_axi_arprot     => (others => '0'),
        s00_axi_arvalid    => '0',
        s00_axi_rready     => '1',

        axis_aclk      => clk,
        axis_aresetn   => resetn,
        s00_axis_tready    => s00_axis_tready,
        s00_axis_tdata     => s00_axis_tdata,
        s00_axis_tstrb     => s00_axis_tstrb,
        s00_axis_tlast     => s00_axis_tlast,
        s00_axis_tvalid    => s00_axis_tvalid,
        m00_axis_tready    => m00_axis_tready,
        
        addra => addra,
        dina => dina,
        douta => douta,
        ena => ena,
        rsta => rsta,
        wea => wea
    );

clk_process :process
begin
    clk <= '0';
    wait for clk_period/2;  
    clk <= '1';
    wait for clk_period/2;  
end process;

process
begin
    wait for 400ns;
    m00_axis_tready <= '1';
    wait;
end process;

main_stim: process
variable ident : integer;  -- 0 or 1; drives weight pattern (sparse: 1 every 9 beats)
-- write_axi: performs a single AXI4-Lite write transaction.
-- The AXI4-Lite bus is 32-bit so data is std_logic_vector(31 downto 0).
-- vec_len is written at offset 0x0; the manager uses it to compute length_div16.
procedure write_axi(constant addr: in integer; constant data: in std_logic_vector(31 downto 0)) is
begin
      s00_axi_wdata <= data;
      s00_axi_awaddr <= "00000";
      s00_axi_awvalid <= '1';
      s00_axi_wvalid <= '1';
      s00_axi_bready <= '1';
      if (s00_axi_awready = '0') then
        wait until s00_axi_awready = '1';
      end if;
      if (s00_axi_wready = '0') then
        wait until s00_axi_wready = '1';
      end if;
      wait for clk_period + clk_period/2;
      s00_axi_awvalid <= '0';
      s00_axi_wvalid <= '0';
      wait for clk_period/2;
      if (s00_axi_bvalid = '0') then
        wait until s00_axi_bvalid = '1';
      end if;
      wait for clk_period + clk_period/2;
      s00_axi_bready <= '0';
      wait for clk_period/2;
end procedure;

begin
    resetn <= '0';
    wait for 20ns;
    resetn <= '1';
    wait for 20ns;
    -- Write vec_len = 8 via AXI4-Lite at offset 0x0.
    -- length_div16 = 8/16 = 0 inside the manager (vec_len < 16 means 0 full groups).
    -- This matches the 32-bit ground truth; adjust to >= 48 for real inference.
    write_axi(0, std_logic_vector(to_unsigned(8, 32)));
    wait for 20ns;
    wait until rising_edge(clk);
    
    -- Phase 1: send 32 weight beats (i=0..31), no tlast.
    -- Weight pattern: ident=1 (weight=1) when i mod 9 = 0, else ident=0 (weight=0).
    -- to_signed(ident, 128) fills the full 128-bit word: either 0x00..01 or 0x00..00.
    -- All 16 byte lanes carry the same value; the manager reads each lane as one DSP input.
    -- Handshake: assert tvalid, clock, then wait for tready to confirm acceptance.
    for i in 0 to 31 loop
      s00_axis_tvalid <= '1';
      if (i mod 9) = 0 then
        ident := 1;
      else
        ident := 0;
      end if; 
      s00_axis_tdata <= std_logic_vector(to_signed(ident, 128));
      wait until rising_edge(clk);
      while s00_axis_tready /= '1' loop
        wait until rising_edge(clk);
      end loop;
    end loop;
    s00_axis_tvalid <= '0';
    wait for 40ns;
    wait until rising_edge(clk);
    
    -- Phase 2: send beats i=32..63, asserting tlast on the final beat (i=63).
    -- tlast signals end-of-frame to the manager, triggering the done state.
    -- The leading tready check prevents driving data before the manager is ready
    -- (important after coming out of the inter-phase idle gap above).
    for i in 32 to 63 loop
      while s00_axis_tready /= '1' loop
        wait until rising_edge(clk);
      end loop;
      s00_axis_tvalid <= '1';
      
      if (i mod 9) = 0 then
        ident := 1;
      else
        ident := 0;
      end if; 
      s00_axis_tdata <= std_logic_vector(to_signed(ident, 128));
      
      if i = 63 then
        s00_axis_tlast <= '1';  -- end-of-frame; manager transitions to finishing/done
      end if;
      
      wait until rising_edge(clk);
      while s00_axis_tready /= '1' loop
        wait until rising_edge(clk);
      end loop;
    end loop;
    s00_axis_tvalid <= '0';
    s00_axis_tlast <= '0';
    wait for 100ns;
    
    -- Simulate PS CDMA writing a new activation row into BRAM port B.
    -- Pulse all 16 byte-enables (x"FFFF") for one 40ns window to commit dinb
    -- (bytes 0x00..0x0F) to address 0. This updates the activations the manager
    -- will read on the next inference pass.
    web <= x"FFFF";
    wait for 40ns;
    web <= x"0000";
    
    wait until rising_edge(clk);
    -- Phase 3: second full inference pass, 64 beats (i=0..63), tlast on last beat.
    -- Loop resets to i=0 (independent counter) to keep the same i mod 9 weight
    -- pattern as phase 1 for a deterministic, repeatable test.
    for i in 0 to 63 loop
      s00_axis_tvalid <= '1';
      
      if (i mod 9) = 0 then
        ident := 1;
      else
        ident := 0;
      end if; 
      s00_axis_tdata <= std_logic_vector(to_signed(ident, 128));
      
      if i = 63 then
        s00_axis_tlast <= '1';  -- end-of-frame for second inference pass
      end if;
      
      wait until rising_edge(clk);
      while s00_axis_tready /= '1' loop
        wait until rising_edge(clk);
      end loop;
    end loop;
    s00_axis_tvalid <= '0';
    s00_axis_tlast <= '0';
    wait;  -- simulation ends here; inspect m00_axis_tdata for neuron outputs
end process;

end Behavioral;
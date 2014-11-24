--////////////////////////////////////////////////////////////////////////////////
--// Author: Luccas Almeida
--// Date: 24/11/2014
--//
--// Based on code from: 
--// lsilvest 02/03/2008
--//
--//
--// Module Name:   sdram_controller
--//
--// Target Devices: Altera DE2-115
--//
--// Tool versions:  Quartus II 13.1 Web Edition
--//
--//
--// Description: This module is an SDRAM controller for 128-Mbyte SDRAM chip
--//              ISSI IS42S16320D. 
--//
--////////////////////////////////////////////////////////////////////////////////
--// Copyright (c) 2008, 2014 Authors
--//
--// Permission is hereby granted, free of charge, to any person obtaining a copy
--// of this software and associated documentation files (the "Software"), to deal
--// in the Software without restriction, including without limitation the rights
--// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--// copies of the Software, and to permit persons to whom the Software is
--// furnished to do so, subject to the following conditions:
--//
--// The above copyright notice and this permission notice shall be included in
--// all copies or substantial portions of the Software.
--//
--// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
--// THE SOFTWARE.
--////////////////////////////////////////////////////////////////////////////////
library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;
-- this is the entity
entity sdram_controller is
  port ( 
	clk 			: in std_logic;
	clk_dram 	: in std_logic;
	rst 			: in std_logic;
	dll_locked 	: in std_logic;
	-- DRAM signals
	dram_addr 	: out std_logic_vector(12 downto 0);
	dram_bank 	: out std_logic_vector(1 downto 0);
	dram_cas_n 	: out std_logic;
	dram_ras_n 	: out std_logic;
	dram_cke 	: out std_logic;
	dram_clk 	: out std_logic;
	dram_cs_n 	: out std_logic;
	dram_dq 		: inout std_logic_vector(31 downto 0);
	dram_dqm 	: out std_logic_vector(3 downto 0);
	dram_we_n 	: out std_logic;
	--wishbone
	addr_i 		: in std_logic_vector(22 downto 0);
	dat_i 		: in std_logic_vector(31 downto 0);
   dat_o 		: out std_logic_vector(31 downto 0);
	we_i 			: in std_logic;
	ack_o 		: out std_logic;
	stb_i			: in std_logic;
	cyc_i			: in std_logic);
end entity sdram_controller;
 
-- this is the architecture
architecture behavioural of sdram_controller is
constant Mode : std_logic_vector(12 downto 0) := "0000000100000";

type States is (Init, Wait200, InitPre, WaitInitPre, InitRef, WaitInitRef, ModeReg, WaitModeReg, Done, Idle, Refresh, WaitRefresh, Act, WaitAct, W0, W1, WPre, R0, R1, R2,R3, RPre, Pre, WaitPre, Error);

constant TRC_CNTR_C : unsigned(3 downto 0) := "0111"; -- ref to ref / act to act
constant RFSH_CNTR_C : unsigned(15 downto 0) := "0000001111101000"; --refresh every 1000cycles =~ 8192 refreshes/64ms
constant TRCD_CNTR_C : unsigned(2 downto 0) := "001"; 
constant TRP_CNTR_C : unsigned(3 downto 0) := "0001";
constant WAIT_200_CNTR_c : unsigned(15 downto 0) := "0110100101111000";

signal addr_r : std_logic_vector(22 downto 0);

signal dram_addr_r : std_logic_vector(12 downto 0) := (others => '0');
signal dram_bank_r : std_logic_vector(1 downto 0) := "00";
signal dram_dq_r : std_logic_vector(31 downto 0) := (others => '0');
signal dram_cas_n_r :std_logic := '0';
signal dram_ras_n_r : std_logic := '0';
signal dram_we_n_r : std_logic := '0';

signal dat_o_r : std_logic_vector(31 downto 0);
signal ack_o_r : std_logic;
signal dat_i_r : std_logic_vector(31 downto 0);
signal we_i_r : std_logic;
signal stb_i_r : std_logic;
signal oe_r : std_logic;

signal current_state : States;
signal next_state : States;

signal init_pre_cntr : unsigned(3 downto 0);
signal trc_cntr : unsigned(3 downto 0);
signal trp_cntr : unsigned(3 downto 0);
signal rfsh_int_cntr : unsigned(15 downto 0);
signal trcd_cntr : unsigned(2 downto 0);
signal wait200_cntr : unsigned(15 downto 0);
signal gwait : unsigned(3 downto 0);
signal do_refresh: std_logic;

begin
	
  -- register command
  process (clk, rst) begin
	if(rst = '0' and  rising_edge(clk)) then
		if ((stb_i_r='1') and (current_state = Act)) then
		  stb_i_r <= '0';
		elsif (stb_i='1' and cyc_i='1') then 
		  addr_r <= addr_i;
		  dat_i_r <= dat_i;
		  we_i_r <= we_i;
		  stb_i_r <= stb_i;
		end if;
    end if;
  end process;
  
  --Wait 200ms counter
  process (clk, rst) begin
    if (rst = '1') then
	    wait200_cntr <= (others => '0');
	 elsif(rising_edge(clk)) then  
		 if (current_state = Init) then
			wait200_cntr <= WAIT_200_CNTR_c;
		 else
			wait200_cntr <= wait200_cntr - 1;
		 end if;
	 end if;
  end process;

	--control the interval between refreshes:
  process (clk, rst) begin
    if (rst='1') then
      rfsh_int_cntr <= (others => '0');   -- immediately initiate new refresh on reset
    elsif(rising_edge(clk)) then
		 if (current_state = WaitRefresh) then
			do_refresh <= '0';
			rfsh_int_cntr <= RFSH_CNTR_C;
		 elsif (rfsh_int_cntr=0) then
			do_refresh <= '1';
		 else
			rfsh_int_cntr <= rfsh_int_cntr - 1 ;
		 end if;
	  end if;
  end process;
  
  
  process (clk, rst) begin
    if (rst='1') then
      trc_cntr <= (others => '0');
	 elsif(rising_edge(clk)) then
		 if (current_state = InitRef or
						  current_state = Refresh) then
			trc_cntr <= TRC_CNTR_C;
		 else
			trc_cntr <= trc_cntr - 1;
		 end if;
    end if;
  end process;
  
    process (clk, rst) begin
    if (rst='1') then
      trp_cntr <= (others => '0');
	 elsif(rising_edge(clk)) then
		 if (current_state = Pre or
				current_state = InitPre) then
			trp_cntr <= TRP_CNTR_C;
		 else
			trp_cntr <= trp_cntr - 1;
		 end if;
    end if;
  end process;


  -- counter to control the activate
  process (clk, rst) begin
    if (rst='1') then
      trcd_cntr <= (others => '0');
	 elsif(rising_edge(clk)) then
		 if (current_state = Act or
						  current_state = ModeReg) then
			trcd_cntr <= TRCD_CNTR_C;
		 else
			trcd_cntr <= trcd_cntr - 1;
		 end if;
	end if;
  end process;
  
   process (clk,rst) begin
    if (rst='1') then
      init_pre_cntr <= (others => '0');
    elsif(rising_edge(clk)) then	
	     if (current_state = Idle or
						current_state = Init) then
					init_pre_cntr <= (others => '0');	
		  elsif (current_state = InitRef or
						current_state = Refresh) then
			init_pre_cntr <= init_pre_cntr + 1;
		 end if;
	end if;
  end process;

  process(clk,rst) begin
    if (rst='1') then 
      current_state <= Init;
    elsif(rising_edge(clk)) then
      current_state <= next_state;
    end if;
  end process;
  

  -- initialization is fairly easy on this chip: wait 200us then issue
  -- 8 precharges before setting the mode register
  -- this is the main controller logic:
  process (next_state, current_state, clk) begin
	if(rst = '1') then
		next_state <= Init;
	else
		case (current_state) is
				when Init =>
															next_state <= Wait200;
			when Wait200 =>
				if (wait200_cntr=0) then         next_state <= InitPre;
				else                             next_state <= Wait200;
				end if;
			when InitPre =>                      
															next_state <= WaitInitPre;
			when WaitInitPre =>
				if (trp_cntr=0) then  				next_state <= InitRef;
				else 										next_state <= WaitInitPre;
				end if;
			when InitRef =>
															next_state <= WaitInitRef;
			when WaitInitRef =>
				if (trc_cntr=0) then
					if (init_pre_cntr = 8) then   next_state <= ModeReg;
					else                          next_state <= InitRef;
				end if;
				else                             next_state <= WaitInitRef;
				end if;
			when ModeReg =>                     next_state <= WaitModeReg;

			when WaitModeReg =>
				if (trcd_cntr=0) then			   next_state <= Done;
				else                             next_state <= WaitModeReg;
			end if;
			when Done =>                       	next_state <= Idle;

			when Idle =>
				if (do_refresh='1') then         next_state <= Refresh;
				elsif (stb_i_r='1') then         next_state <= Act;
				else                          	next_state <= Idle;
				end if;
			when Refresh =>                    	next_state <= WaitRefresh;

			when WaitRefresh =>
				if (trc_cntr=0) then					next_state <= Idle;
				else                             next_state <= WaitRefresh;
				end if;
			when ACT =>                         next_state <= WaitAct;
		  
			when WaitAct =>
				if (0=trcd_cntr) then 
					if (we_i_r='1') then          next_state <= W0;
					else                        	next_state <= R0;
				end if;	
				else                           	next_state <= WaitAct;
				end if;
			when W0 =>                      		next_state <= WPre;
			
			when W1 =>                      		next_state <= WPre;

			when WPre =>                   		next_state <= Pre;
		  
			when R0 =>                       	next_state <= R1;

			when R1 =>                       	next_state <= R2;
		  
			when R2 =>                       	next_state <= R3;
		  
			when R3 =>                       	next_state <= RPre;

			when RPre =>                    		next_state <= Pre;
		  
			when Pre =>                        	next_state <= WaitPre;
		  
		  when WaitPre =>
			-- if the next command was not another row activate in the same bank
			-- we could wait tRCD ofanly; for simplicity but at the detriment of
			-- efficiency we always wait tRC
				if (trp_cntr=0) then             next_state <= Idle;
				else                         		next_state <= WaitPre;
				end if;
				when others =>                	next_state <= Error;        
		end case;
		end if;
	end process;

  
  -- ack_o signal
  process(clk, rst) begin
	if (rst='1') then 
	    ack_o_r <= '0';
	elsif(rising_edge(clk)) then
		if (current_state = WaitPre) then
		  ack_o_r <= '0';
		elsif (current_state = RPre or
			current_state = WPre) then
		  ack_o_r <= '1';
		end if;
	end if;
	end process;

  
  -- data
  process(clk, rst) begin
    if (rst='1') then
      dat_o_r <= (others => '0');
      dram_dq_r <= (others => '0');
      oe_r <= '0';
	elsif(rising_edge(clk)) then
		 if (current_state = W0) then
			dram_dq_r <= dat_i_r;
			oe_r <= '1';
		 elsif (current_state = R2) then
			dat_o_r <= dram_dq;
			dram_dq_r <= (others => 'Z');
			oe_r <= '0';
		 else
			dram_dq_r <= (others => 'Z');
			oe_r <= '0';
		 end if;
	end if;
  end process;

  
  -- address
  process(clk) begin
    if(rising_edge(clk)) then
		 if (current_state = ModeReg) then
			dram_addr_r <= Mode;
		 elsif (current_state = InitPre or
						current_state = pre) then
			dram_addr_r <= "0010000000000";
		 elsif (current_state = Act) then
			dram_addr_r <= "00" & addr_r(20 downto 10);
			dram_bank_r <= addr_r(22 downto 21);
		 elsif (current_state = W0 or current_state = R0) then
			dram_addr_r <= "000" & addr_r(9 downto 0);
			dram_bank_r <= addr_r(22 downto 21);
		 else
			dram_addr_r <= (others => '0');
			dram_bank_r <= (others => '0');
		 end if;
	 end if;
  end process;

  
  -- commands
  process(clk) begin
	 if(rising_edge(clk)) then
		if(current_state = Init) then
			dram_dqm <= (others => '1');
		elsif (current_state = Done) then
			dram_dqm <= (others => '0');
		end if;
		 if(current_state = InitPre or
		    current_state = InitRef or
		    current_state = Pre or
			 current_state = ModeReg or
			 current_state = Refresh or
			 current_state = Act) then
			 dram_ras_n_r <= '0' ;
		 else
			 dram_ras_n_r <= '1';
		  end if;
		if (current_state = R0 or
			 current_state = W0 or
			 current_state = InitRef or
			 current_state = Refresh or
			 current_state = ModeReg) then
			 dram_cas_n_r <= '0' ;
		 else
			 dram_cas_n_r <= '1';
		  end if;
		if (current_state = InitPre or
		    current_state = Pre or
			current_state = W0 or
			current_state = ModeReg
			)then
			dram_we_n_r <= '0' ;
		else
			dram_we_n_r <= '1';
		end if;
	end if;
  end process;
	
	dram_addr <= dram_addr_r;
	dram_bank <= dram_bank_r;
	dram_cas_n <= dram_cas_n_r;
	dram_ras_n <= dram_ras_n_r;
	dram_we_n <= dram_we_n_r;
	dram_dq <= dram_dq_r when oe_r = '1' else
				(others => 'Z');
	
	dat_o <= dat_o_r;
	ack_o <= ack_o_r;
	
	dram_cke <= '1';
	dram_cs_n <= not dll_locked;
	dram_clk <= clk_dram;
end architecture behavioural;
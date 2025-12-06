# ECE9933_GenAI_Trojan
Using GHOST to insert Trojans into OpenTitan

The folder structure for now is as follows - 
- trojan
	- ai 
		- contains the ai logs used to generate the trojan insertion
		- contains the prompts provided to the GHOST script, and the output of the ai model 
		- will be modified to all logs for testbench generation, and rtl code modification (if required)
	
	- rtl 
		- contains only the rtl code of the modified ip file (core) - where the trojan was inserted
		- the rest of the rtl code remains unchanged wrt to the opentitan repository
	
	- tb
		- will contain the testbench used to trigger and catch the trojan
		- to be completed - working on figuring out the testbench and DV structure of opentitan to replicate it

- report

# Spatial fixed effects Panel Analysis Method (SPAM)

This is a fixed effects panel analysis function. It uses a method from econometrics to detect trends over time across a window of pixels. This increases the robustness of trend analysis as compared to a pixel by pixel analysis. An added benefit is the speed you gain as you downscale the original data by a factor defined by the panel size used.

The function makes use of the Panel Data Econometrics "plm" package in R. A detailed overview can be found in [this publication](http://www.jstatsoft.org/v27/i02/paper).

## Installation

Download and unzip the project in a local directory.

In R set the working path to the R script folder and source the SPAM script file in R.

	setwd(/foo/bar/R)
	source(/foo/bar/R/panel_analysis.r)

The function relies on the R raster() library, so make sure the library and all it's dependencies are installed.

## Use

Use the test data provided to explore the functionality of the routine, e.g. you can run the panel analysis on the alaska GPP data provided using the following command. This will invoke an analysis on 6 cpu's with a panel size of 3 pixels. The data will be plotted at the end of the analysis and stored in the "my_panel_data" variable.
	
	require(raster)
	require(maps)

	# load the test data
	r <- brick("Alaska_annual_GPP.tif")

	# run SPAM
	my_panel_data <- panel_analysis(r,panel_size=3,cpu=6,plot=F)

	# plot the results with an outline overlay
	plot(my_panel_data$layer.1)
	map('world',add=TRUE)

panel_analysis <- function(r=rasterfile,panel_size=10,cpu=6,filename="",plot=TRUE){

  # load packages, note raster should be loaded as it only
  # takes raster input
  require(raster)
  require(reshape)
  require(plm)
  require(doSNOW)
  
  # general input file check / is the input of the right class
  # and does it have enough layers to do a regression analysis
  # which makes sense
  if (class(r)[1] == "RasterStack" || class(r)[1] == "RasterBrick" || class(r)[1] == "array"){ 
    # get the number of layers in the file
    # it is assumed that every layer is a year
    # in consecutive order
    lyrs = dim(r)[3]
    
    if (lyrs <= 3){
      stop("Z-dimension of the data cube has <= 3 time steps.\n
         Panel analysis will be unreliable!")
    }
  
    } else {
    stop("Input file is not an array, RasterBrick or RasterStack!")
  }
  
  # if it's a rasterstack or brick (in memory)
  if (class(r)[1]=="RasterStack" || class(r)[1]=="RasterBrick" ){  
    # convert to array (IN MEMORY -- only proceed with enough memory)
    r_array = as.array(r)
  }  
  
  if (class(r)[1]=="array"){
    r_array = r
  }
  
  # this is MODIS snow cover trend specific
  r_array[r_array <= 15 ] = NA
  
  # setup parallel backend if more than
  # 1 cpu is requested
  if (cpu > 1){
   cl<-makeCluster(cpu)
   registerDoSNOW(cl)
  }
  
  # determine how many rows and columns 
  # there will be in the output file
  output_cols = ceiling(r@ncols/panel_size)
  output_rows = ceiling(r@nrows/panel_size)
  
  # coordinate sequences for both columns
  # and row locations.
  # we process panels of AxA pixels
  col_seq = seq(1,r@ncols,by=panel_size)
  row_seq = seq(1,r@nrows,by=panel_size)
  
  # convert to two identical matrices
  # and unwrap as vector
  loc_col_mat = as.vector(matrix(rep(col_seq,output_rows),output_rows,output_cols,byrow=T))
  loc_row_mat = as.vector(matrix(rep(row_seq,output_cols),output_rows,output_cols,byrow=F))
  
  # we unwrap these to form a location matrix
  # with pairs of row and column locations
  loc_mat = cbind(loc_row_mat,loc_col_mat)
  
  # we cycle through all the locations
  # in parallel if possible and compute
  # the panel analysis data
  
  # helper function
  plm_block_process <- function(i){
    
    # subtract 1 from panel size
    # otherwise we have panel_size +1 elements
    px = panel_size - 1
    
    # calculate the maximum row and
    # column location
    max_row = loc_mat[i,1]+px
    max_col = loc_mat[i,2]+px
    
    # these maximum row and column locations
    # should not exceed the dimensions of the matrix
    if ( max_row > dim(r_array)[1] ){
      max_row = dim(r_array)[1]
    }
    
    if ( max_col > dim(r_array)[2] ){
      max_col = dim(r_array)[2]
    }
    
    # extract a chunck out of our 3D array into a small
    # temporary array
    tmp_arr = r_array[loc_mat[i,1]:max_row,loc_mat[i,2]:max_col,]
        
    # flatten this temporary array using melt
    # if ther is only one sliver of pixels the resulting
    # operation above results in a 2D image, we compensate
    # for this exception
    if (length(dim(tmp_arr)) == 3){
      tmp_mat = melt(tmp_arr,varnames=c("X","Y","step"))[,3:4]
    }else{
      tmp_mat = melt(tmp_arr)[,2:3]
    }
    
    # construct an index for the pixels in this array
    # [is a factor!!]
    id = factor(rep(1:prod(dim(tmp_arr)[1:2]),lyrs))
    yr = factor(sort(rep(2001:(2000+lyrs), prod(dim(tmp_arr)[1:2]))))
    
    # merge everything in a data frame
    tmp_mat = data.frame(id,yr,tmp_mat)
    tmp_mat = tmp_mat[order(tmp_mat$id),]
    
    # panel analysis with fixed effects
    # fixed slope, varying intercept per pixels series
    # always use <- for assignments in try NEVER =
    # it will fail witht he unused argument error
    try( plm_summary <- summary(plm(value ~ step,data=tmp_mat,index=c("id"),model="within")),
         silent=TRUE)
    
    # the panel analysis will not return results when values are
    # all NA or all equal (no trend), check if the plm analysis returns
    # results, if so report these otherwise return NA
    if(exists("plm_summary")){
      return(c(plm_summary$coefficients[1,1],plm_summary$r.squared[1],plm_summary$fstatistic$p.value))
    }else{
      return(c(NA,NA,NA))
    }
  }
  
  # this is the major worker in the analysis
  # foreach loops over every location in the location matrix
  # (in parallel if available) and calculates the panel analysis
  # across all pixels within a given block defined by the panel size
  # it will return the results (slope, R^2, p-value) to the output
  # matrix
  
  if (cpu > 1){ # run in paralllel if possible
    plm_output = foreach (i=1:dim(loc_mat)[1],.packages=c("reshape","plm"),.combine=rbind) %dopar%  
              { plm_block_process(i) }
  } else {
    plm_output = foreach (i=1:dim(loc_mat)[1],.packages=c("reshape","plm"),.combine=rbind) %do%  
              { plm_block_process(i) }
  }
  
  # end cluster gracefully
  # not needed after the foreach routine
  if (cpu > 1){
    stopCluster(cl)
  }
  
  # convert the output to a raster image
  # first convert the 3 column matrix into a long
  # vector, then reshape it into an array with 3
  # Z-layers and an X-Y coordinate. Finally,
  # convert it to a rasterbrick with 3 layers
  rb = brick(array(as.vector(plm_output),dim=c(output_rows,output_cols,3)))
  
  if (class(r)[1]=="RasterStack" || class(r)[1]=="RasterBrick" ){  
        
    # GEO-REFERENCING the new file if the input was projected
    # Correcting the difference in pixels between the original image and the one
    # we construct with 'new' panel sized pixels. The new pixels size
    # might not align with the original pixel size overshooting in pixels
    # from time to time.
    col_offset = (col_seq[output_cols] + panel_size - 1) - ncol(r)
    row_offset = (row_seq[output_rows] + panel_size - 1) - nrow(r)
    
    # grab original extent from input raster stack
    # add offset * resolution to the edges
    new_extent = extent(r)
    new_extent@xmax = new_extent@xmax + (col_offset * xres(r))
    new_extent@ymin = new_extent@ymin - (row_offset * yres(r))
    
    # set new projection
    extent(rb) = new_extent
    
    # add the input file's projection / same as original
    projection(rb) = projection(r)
  }
  
  # plot data if requested
  if (plot == TRUE || plot == T){
  plot(rb$layer.1)
  }
 
  # do we write to file
  if (filename != "" ){
    writeRaster(rb,filename,overwrite=TRUE,options=c("COMPRESS=DEFLATE"))
  }
  
  # return our file
  return(rb)
}
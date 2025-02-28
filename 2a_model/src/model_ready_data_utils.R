#' @title Match site ids to segment data
#'
#' @description 
#' Function to match site ids to segment data, including meteorological data
#' or segment attribute data.
#'
#' @param seg_data a data frame of meterological data with either column 
#' seg_id_nat' or 'COMID'.
#' @param sites_w_segs a dataframe with both segment ids ('segidnat' or 'COMID') 
#' and site ids ('site_id').
#'
#' @returns 
#' Returns a data frame of seg data with site ids.
#' 
match_site_ids_to_segs <- function(seg_data, sites_w_segs) {
    
    if(any(grepl('COMID', names(seg_data)))){
      seg_data_out <- seg_data %>%
        mutate(COMID = as.character(COMID)) %>%
        left_join(y = sites_w_segs[,c("site_id","COMID")],
                  by = "COMID") %>%
        arrange(site_id)
    } else {
      seg_data_out <- seg_data %>%
        left_join(sites_w_segs[,c("site_id","segidnat")],
                  by = c("seg_id_nat" = "segidnat"))
    }
    
    return(seg_data_out)
  }


#' @title Write R data frame to zarr
#' 
#' @description 
#' Function to use reticulate to write an R data frame to a Zarr data store, 
#' which is the file format river-dl currently takes.
#'
#' @param df a data frame of data
#' @param index vector of strings - the column(s) that should be the index
#' @param out_zarr where the zarr data will be written
#'
#' @returns 
#' Returns the out_zarr path.
#' 
write_df_to_zarr <- function(df, index_cols, out_zarr) {
  
  # convert to a python (pandas) DataFrame so we have access to the object methods (set_index and to_xarray)
  py_df <- reticulate::r_to_py(df)
  pd <- reticulate::import("pandas")
  py_df[["date"]] = pd$to_datetime(py_df$date)
  py_df[["site_id"]] = py_df$site_id$astype("str")

  
  # set the index so that when we convert to an xarray dataset it is indexed properly
  py_df  <- py_df$set_index(index_cols)

  
  # convert to an xarray dataset
  ds <- py_df$to_xarray()
  ds$to_zarr(out_zarr, mode = 'w')

  
  return(out_zarr)
  
}


#' @title Write R data frame to zarr
#' 
#' @description 
#' Function to write out to zarr and optionally take a subset. This assumes your
#' zarr index names will be "site_id" and "date".
#'
#' @param df a data frame of data
#' @param out_zarr where the zarr data will be written
#' @param sites_subset - character vector of sites to subset to 
#'
#' @returns 
#' Returns the out_zarr path.
#' 
subset_and_write_zarr <- function(df, out_zarr, sites_subset = NULL){

    if (!is.null(sites_subset)){
      df <- df %>% filter(site_id %in% sites_subset)
    }
  out_zarr <- write_df_to_zarr(df, c("site_id", "date"), out_zarr)
  return(out_zarr)
}


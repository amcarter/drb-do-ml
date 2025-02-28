source("1_fetch/src/fetch_sb_data.R")
source("1_fetch/src/get_nwis_sites.R")
source("1_fetch/src/get_daily_nwis_data.R")
source("1_fetch/src/get_inst_nwis_data.R")
source("1_fetch/src/write_data.R")
source("1_fetch/src/summarize_timeseries.R")
source("1_fetch/src/download_nhdplus_flowlines.R")
source("1_fetch/src/fetch_nhdv2_attributes_from_sb.R")

p1_targets_list <- list(
  
  # download WQP data product from science base for discrete samples
  tar_target(
    p1_wqp_data_file,
    download_sb_file(sb_id = "5e010424e4b0b207aa033d8c",
                     file_name = "Water-Quality Data.zip",
                     out_dir="1_fetch/out"),
    format = "file"
  ),

  # load WQP data into R object
  tar_target(
    p1_wqp_data,
    {
      unzip(zipfile = p1_wqp_data_file, exdir = "1_fetch/out", overwrite = TRUE)
      readRDS(paste("1_fetch/out","/Water-Quality Data/DRB.WQdata.rds", sep = ""))
    }
  ),
  
  # Identify NWIS sites with DO data 
  tar_target(
    p1_nwis_sites,
    {
      dummy <- dummy_date
      get_nwis_sites(drb_huc8s, pcode_select, site_tp_select, stat_cd_select)
    }
  ),
  
  # Subset daily NWIS sites
  tar_target(
    p1_nwis_sites_daily,
    p1_nwis_sites %>%
      # retain "dv" sites that contain data records after user-specified `earliest_date`
      filter(data_type_cd == "dv",
             !(site_no %in% omit_nwis_sites), 
             end_date > earliest_date) %>%
      # for sites with multiple time series (ts_id), retain the most recent time series for site_info
      group_by(site_no) %>% 
      arrange(desc(end_date)) %>% 
      slice(1)
    ),
  
  # Download NWIS daily data
  tar_target(
    p1_daily_data,
    get_daily_nwis_data(site_info = p1_nwis_sites_daily,
                        parameter = pcode_select,
                        stat_cd_select = stat_cd_select,
                        start_date = earliest_date,
                        end_date = latest_date),
    pattern = map(p1_nwis_sites_daily)
  ),


  # Download NWIS daily data for other parameters (flow, temperature, SC) (see codes below)
  tar_target(
    p1_daily_aux_data,
    dataRetrieval::readNWISdv(
                              siteNumbers = p1_nwis_sites_daily$site_no,
                              parameterCd = c("00060", "00010", "00095"),
                              statCd = stat_cd_select,
                              startDate = earliest_date,
                              endDate = latest_date) %>%
    dataRetrieval::renameNWISColumns() %>%
    select(!starts_with("..2..")),
    pattern = map(p1_nwis_sites_daily)
  ),

  # Save daily aux data to csv
  tar_target(
    p1_daily_aux_csv,
    write_to_csv(p1_daily_aux_data, outfile="1_fetch/out/daily_aux_data.csv"),
    format = "file"
  ),
  
  # Subset NWIS sites with instantaneous (sub-daily) data
  tar_target(
    p1_nwis_sites_inst,
    p1_nwis_sites %>%
      # retain "uv" sites that contain data records after user-specified `earliest_date` and
      # before user-specified `latest_date`
      filter(data_type_cd == "uv",
             !(site_no %in% omit_nwis_sites),
             end_date > earliest_date,
             begin_date < latest_date) %>%
      # for sites with multiple time series (ts_id), retain the most recent time series for site_info
      group_by(site_no) %>% arrange(desc(end_date)) %>% slice(1)
  ),
  
  # Download NWIS instantaneous data
  tar_target(
    p1_inst_data,
    get_inst_nwis_data(site_info =p1_nwis_sites_inst,
                       parameter = pcode_select,
                       start_date = earliest_date,
                       end_date = latest_date),
    pattern = map(p1_nwis_sites_inst)
  ),
  
  # Create log file to track sites with multiple time series
  tar_target(
    p1_nwis_sites_inst_multipleTS_csv,
    p1_nwis_sites %>%
      # retain "uv" sites that contain data records after user-specified `earliest_date`
      filter(data_type_cd == "uv",
             !(site_no %in% omit_nwis_sites),
             end_date > earliest_date) %>%
      # save record of sites with multiple time series
      group_by(site_no) %>% mutate(count_ts = length(unique(ts_id))) %>%
      filter(count_ts > 1) %>%
      readr::write_csv(.,"1_fetch/log/summary_multiple_inst_ts.csv")
  ),
  
  # Create and save summary log file for NWIS daily data
  tar_target(
    p1_daily_timeseries_summary_csv,
    command = target_summary_stats(p1_daily_data,"Value","1_fetch/log/daily_timeseries_summary.csv"),
    format = "file"
  ),
  
  # Create and save summary log file for NWIS instantaneous data
  tar_target(
    p1_inst_timeseries_summary_csv,
    command = target_summary_stats(p1_inst_data,"Value_Inst","1_fetch/log/inst_timeseries_summary.csv"),
    format = "file"
  ),

  # Create sf polygon that represents the area of interest (AOI) based 
  # on the HUC8 identifiers defined in _targets.R
  tar_target(
    p1_lower_drb_aoi,
    drb_huc8s %>%
      lapply(.,function(x){
        # download huc8 basin polygon
        nhdplusTools::get_huc8(id = x)
      }) %>%
      bind_rows() %>%
      sf::st_bbox() %>%
      sf::st_as_sfc()
  ),
  
  # Fetch NHDv2 flowline reaches for the full DRB, and then subset data frame
  # to only include flowlines within the lower DRB. 
  tar_target(
    p1_nhd_reaches_sf,
    download_nhdplus_flowlines(aoi = p1_lower_drb_aoi) %>%
      mutate(huc8 = stringr::str_sub(REACHCODE, start = 1, end = 8)) %>%
      filter(huc8 %in% drb_huc8s)
  ),
  
  # Read in csv file containing the segment/catchment attributes that we want
  # to download from ScienceBase:
  tar_target(
    p1_sb_attributes_csv,
    '1_fetch/in/target_sciencebase_attributes.csv',
    format = 'file'
  ),
  
  # Read in and format segment/catchment attribute datasets from ScienceBase 
  # note: use tar_group to define row groups based on ScienceBase ID; 
  # row groups facilitate branching over subsets of the sb_attributes 
  # table in downstream targets
  tar_target(
    p1_sb_attributes,
    read_csv(p1_sb_attributes_csv, show_col_types = FALSE) %>%
      # parse sb_id from https link 
      mutate(sb_id = str_extract(SB_link,"[^/]*$")) %>%
      group_by(sb_id) %>%
      tar_group(),
    iteration = "group"
  ),
  
  # Map over desired attribute datasets to download NHDv2 attribute data 
  tar_target(
    p1_sb_attributes_downloaded_csvs,
    fetch_nhdv2_attributes_from_sb(vars_item = p1_sb_attributes, 
                                   save_dir = "1_fetch/out", 
                                   comids = p1_nhd_reaches_sf$COMID, 
                                   delete_local_copies = TRUE),
    pattern = map(p1_sb_attributes),
    format = "file"
  ),
  
  # Track crosswalk table that maps NLCD land cover classifications to 
  # preferred land cover groupings. 
  tar_target(
    p1_nlcd_reclassification_table_csv,
    "1_fetch/in/nlcd_landcover_reclassification.csv",
    format = 'file'
  ),
  
  # Read in NLCD reclassification table.
  tar_target(
    p1_nlcd_reclassification_table,
    read_csv(p1_nlcd_reclassification_table_csv, show_col_types = FALSE),
  ),

  # Download and unzip metabolism estimates from Appling et al. 2018:
  # https://www.sciencebase.gov/catalog/item/59eb9c0ae4b0026a55ffe389
  tar_target(
    p1_metab_tsv,
    {
    metab_file <- download_sb_file(sb_id = "59eb9c0ae4b0026a55ffe389",
                                   file_name = "daily_predictions.zip",
                                   out_dir="1_fetch/out")
    unzip(zipfile=metab_file, exdir = dirname(metab_file), overwrite=TRUE)
    file.path(dirname(metab_file), "daily_predictions.tsv")
    },
    format="file" 
  ),
  
  # Load downloaded metabolism estimates
  tar_target(
    p1_metab,
      read_tsv(p1_metab_tsv, show_col_types = FALSE) %>%
      # create a new column "site_id". This column is the same as site_name from the
      # original data, but the 'nwis_' before the site number is removed to match site naming
      # conventions used in our pipeline.
      mutate(site_id = str_replace(site_name, "nwis_", ""))
    
  ),
  
  # Download and unzip metabolism diagnostics from https://www.sciencebase.gov/catalog/item/59eb9bafe4b0026a55ffe382
  # metab diagnostics contains 1 row per streamMetabolizer model for each site
  tar_target(
    p1_metab_diagnostics_tsv,
    {
    diagnostics_file <- download_sb_file(sb_id = "59eb9bafe4b0026a55ffe382",
                                         file_name = "diagnostics.zip",
                                         out_dir="1_fetch/out")
    unzip(zipfile=diagnostics_file, exdir = dirname(diagnostics_file), overwrite=TRUE)
    file.path(dirname(diagnostics_file), "diagnostics.tsv")
    }
  ),
  
  tar_target(
    p1_metab_diagnostics,
    read_tsv(p1_metab_diagnostics_tsv, show_col_types = FALSE) %>%
      # create a new column "site_id"; see p1_metab target for details.
      mutate(site_id = str_replace(site, "nwis_",""),
             resolution = str_replace(resolution, "min",""))
  ),
  
  # Load table containing QC'ed site-to-NHD matches for the lower DRB. This 
  # table was generated by comparing the matched COMID from 
  # 2_process/src/match_sites_reaches.R with the matched COMID given in the
  # ref-gages dataset (https://github.com/internetofwater/ref_gages), and 
  # visually inspecting sites where those COMID's differed. 
  tar_target(
    p1_ref_gages_manual_csv,
    "1_fetch/in/refgages_manual.csv",
    format = "file"
  ),
  tar_target(
    p1_ref_gages_manual,
    read_csv(p1_ref_gages_manual_csv, col_types = cols(.default = "c")) %>%
      mutate(id = str_replace(provider_id, "USGS-","")) %>%
      relocate(id, .after = provider_id)
  ),
  
  # Read in meteorological data aggregated to NHDPlusV2 catchments for the 
  # DRB (prepped in https://github.com/USGS-R/drb_gridmet_tools). Note that
  # the DRB met data file must be stored in 1_fetch/in. If working outside
  # of tallgrass/caldera, this file will need to be downloaded from the project
  # S3 bucket and manually placed in 1_fetch/in.
  tar_target(
    p1_drb_nhd_gridmet,
    "1_fetch/in/drb_climate_2022_06_14.nc",
    format = "file"
  )

)  


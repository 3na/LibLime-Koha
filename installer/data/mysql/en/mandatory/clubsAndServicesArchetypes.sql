INSERT INTO  clubsAndServicesArchetypes
(casaId,type,title,description,publicEnrollment,casData1Title,casData2Title,casData3Title,caseData1Title,caseData2Title,caseData3Title,casData1Desc,casData2Desc,casData3Desc,caseData1Desc,caseData2Desc,caseData3Desc,caseRequireEmail,branchcode,last_updated)
values
(1,"club","Bestsellers Club","This club archetype gives the patrons the ability join a club for a given author and for staff to batch generate a holds list which shuffles the holds queue when specific titles or books by certain authors are received.","0","Title","Author","Item Types","","","","If filled in, the the club will only apply to books where the title matches this field. Must be identical to the MARC field mapped to title.","If filled in, the the club will only apply to books where the author matches this field. Must be identical to the MARC field mapped to author.","Put a list of space separated Item Types here for that this club should work for. Leave it blank for all item types.",NULL,NULL,NULL,1,NULL,"2012-07-09 18:33:10"),
(2,"service","New Items E-mail List","This club archetype gives the patrons the ability join a mailing list which will e-mail weekly lists of new items for the given itemtype and callnumber combination given.","0","Itemtype","Callnumber","","","","","The Itemtype to be looked up. Use % for all itemtypes.","The callnumber to look up. Use % as wildcard.","",NULL,NULL,NULL,0,NULL,"2012-07-09 18:33:10");
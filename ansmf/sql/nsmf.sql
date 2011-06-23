CREATE TABLE IF NOT EXISTS `nsmf`.`nsmf_agent` (
  `agent_id` INT NOT NULL AUTO_INCREMENT,
  `agent_name` VARCHAR(45) NOT NULL ,
  `agent_password` VARCHAR(45) NOT NULL ,
  `agent_description` VARCHAR(45) NULL ,
  `agent_ip` INT NULL ,
  `agent_network` VARCHAR(45) NULL ,
  `agent_active` TINYINT(1)  NOT NULL DEFAULT 0 ,
  PRIMARY KEY (`agent_id`)
);

CREATE UNIQUE INDEX `agent_name_UNIQUE` ON `nsmf_agent` (`agent_name` ASC);

CREATE TABLE IF NOT EXISTS `nsmf`.`nsmf_node` (
  `node_id` INT NOT NULL AUTO_INCREMENT,
  `node_name` VARCHAR(45) NOT NULL ,
  `node_description` VARCHAR(45) NULL ,
  `node_type` VARCHAR(45) NOT NULL ,
  PRIMARY KEY (`node_id`)
);

CREATE  UNIQUE INDEX `node_name_UNIQUE` ON `nsmf_node` (`node_name` ASC);
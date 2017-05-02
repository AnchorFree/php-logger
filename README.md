# PHP logger

Logger for any PHP-FPM based project, which seamlessly integrated into standard devops logging solution. 

It was designed in a way, that each PHP application has it's own PHP logger container, but in case you want to share container - you just need to make sure you share necessary volume among all the involved containers. 

#### configuration
It should receive `-q` flag during startup for production usage. Logger accepts following ENV variables:

- TEAM  - configure team this application belongs to. e.g. "elite". This will make filtering and dashboarding easier for teams. 
- APPICATION - configures application name. In case team has more than 1 application - we can see logs for that application specifically. 

